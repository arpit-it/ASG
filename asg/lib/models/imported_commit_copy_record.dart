// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'imported_commit_copy_observation.dart';
import 'imported_commit_copy_request.dart';
import 'structured_proposal_json.dart';

enum ImportedCommitCopyPhase { pending, prepared, refused, unconfirmed }

/// Immutable operation history, never restart process ownership or current consent.
final class ImportedCommitCopyAttempt {
  const ImportedCommitCopyAttempt._(
    this.request,
    this.phase,
    this.observation,
    this.startedAt,
    this.finishedAt,
    this.acknowledgedAt,
  );
  final ImportedCommitCopyRequest request;
  final ImportedCommitCopyPhase phase;
  final ImportedCommitCopyObservation? observation;
  final DateTime startedAt;
  final DateTime? finishedAt, acknowledgedAt;
  bool get needsRecovery =>
      phase != ImportedCommitCopyPhase.prepared && acknowledgedAt == null;
  Map<String, Object?> toJson() => {
    'request': request.requestJson,
    'phase': phase.name,
    'observation': observation?.recordJson,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'acknowledgedAt': acknowledgedAt?.toIso8601String(),
  };
}

final class ImportedCommitCopyRecord {
  ImportedCommitCopyRecord._(
    this.root,
    List<ImportedCommitCopyAttempt> attempts,
    this.recordJson,
    this.digest,
  ) : attempts = List.unmodifiable(attempts);
  static const byteLimit = 512 * 1024, attemptLimit = 16;
  final String root, recordJson, digest;
  final List<ImportedCommitCopyAttempt> attempts;
  ImportedCommitCopyAttempt? get latest =>
      attempts.isEmpty ? null : attempts.last;
  bool get needsRecovery => latest?.needsRecovery ?? false;
  bool get canBegin => !needsRecovery && attempts.length < attemptLimit;
  ImportedCommitCopyAttempt? get lastPrepared {
    for (final attempt in attempts.reversed) {
      if (attempt.phase == ImportedCommitCopyPhase.prepared) return attempt;
    }
    return null;
  }

  factory ImportedCommitCopyRecord.empty(String root) => _build(root, []);
  static ImportedCommitCopyRecord _build(
    String root,
    List<ImportedCommitCopyAttempt> attempts,
  ) => ImportedCommitCopyRecord.decode(
    jsonEncode({
      'version': 1,
      'scope': 'imported-commit-copy-history',
      'root': root,
      'attempts': attempts.map((a) => a.toJson()).toList(),
    }),
  );

  ImportedCommitCopyRecord begin(
    ImportedCommitCopyRequest request,
    DateTime at,
  ) {
    if (!canBegin ||
        request.root != root ||
        attempts.any((a) => a.request.attemptId == request.attemptId)) {
      throw StateError(
        'Copy history requires recovery or has reached its limit.',
      );
    }
    return _build(root, [
      ...attempts,
      ImportedCommitCopyAttempt._(
        request,
        ImportedCommitCopyPhase.pending,
        null,
        at.toUtc(),
        null,
        null,
      ),
    ]);
  }

  ImportedCommitCopyRecord settle(
    ImportedCommitCopyRequest request,
    ImportedCommitCopyObservation? observation,
    DateTime at, {
    bool unconfirmed = false,
  }) {
    final last = latest;
    if (last == null ||
        last.phase != ImportedCommitCopyPhase.pending ||
        last.acknowledgedAt != null ||
        !last.request.matches(request) ||
        (!unconfirmed && observation == null)) {
      throw StateError('Copy attempt changed. Reload history.');
    }
    final checked = observation == null
        ? null
        : ImportedCommitCopyObservation.fromJson(
            observation.recordJson,
            request: request,
          );
    final phase = unconfirmed
        ? ImportedCommitCopyPhase.unconfirmed
        : checked!.status == ImportedCommitCopyStatus.prepared
        ? ImportedCommitCopyPhase.prepared
        : ImportedCommitCopyPhase.refused;
    return _build(root, [
      ...attempts.take(attempts.length - 1),
      ImportedCommitCopyAttempt._(
        request,
        phase,
        checked,
        last.startedAt,
        at.toUtc(),
        null,
      ),
    ]);
  }

  /// Operator acknowledgement records inspection only; it promotes no receipt,
  /// replays no operation and cannot establish that a saved PID is safe to kill.
  ImportedCommitCopyRecord acknowledge(DateTime at) {
    final last = latest;
    if (last == null || !last.needsRecovery) {
      throw StateError('No unresolved copy attempt.');
    }
    return _build(root, [
      ...attempts.take(attempts.length - 1),
      ImportedCommitCopyAttempt._(
        last.request,
        last.phase,
        last.observation,
        last.startedAt,
        last.finishedAt,
        at.toUtc(),
      ),
    ]);
  }

  factory ImportedCommitCopyRecord.decode(String raw) {
    try {
      if (raw.length > byteLimit || utf8.encode(raw).length > byteLimit) {
        throw const FormatException();
      }
      final data = jsonDecode(raw);
      rejectDuplicateJsonMembers(raw);
      if (data is! Map<String, dynamic> ||
          data.length != 4 ||
          !data.keys.toSet().containsAll({
            'version',
            'scope',
            'root',
            'attempts',
          }) ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['scope'] != 'imported-commit-copy-history' ||
          data['root'] is! String ||
          !ImportedCommitCopyRequest.validPath(data['root'] as String) ||
          data['attempts'] is! List ||
          (data['attempts'] as List).length > attemptLimit) {
        throw const FormatException();
      }
      final root = data['root'] as String,
          attempts = <ImportedCommitCopyAttempt>[];
      final ids = <String>{};
      for (final row in data['attempts'] as List) {
        if (row is! Map<String, dynamic> ||
            row.length != 6 ||
            !row.keys.toSet().containsAll({
              'request',
              'phase',
              'observation',
              'startedAt',
              'finishedAt',
              'acknowledgedAt',
            }) ||
            row['request'] is! String ||
            row['phase'] is! String) {
          throw const FormatException();
        }
        final request = ImportedCommitCopyRequest.restore(
          row['request'] as String,
        );
        if (request.root != root || !ids.add(request.attemptId)) {
          throw const FormatException();
        }
        final phase = ImportedCommitCopyPhase.values.singleWhere(
          (v) => v.name == row['phase'],
        );
        final observation = row['observation'] == null
            ? null
            : ImportedCommitCopyObservation.fromJson(
                row['observation'] as String,
                request: request,
              );
        if (observation != null &&
            observation.recordJson != row['observation']) {
          throw const FormatException();
        }
        final started = _time(row['startedAt']);
        final finished = row['finishedAt'] == null
            ? null
            : _time(row['finishedAt']);
        final acknowledged = row['acknowledgedAt'] == null
            ? null
            : _time(row['acknowledgedAt']);
        if ((finished != null && finished.isBefore(started)) ||
            (acknowledged != null &&
                acknowledged.isBefore(finished ?? started)) ||
            (phase == ImportedCommitCopyPhase.pending &&
                (finished != null || observation != null)) ||
            (phase != ImportedCommitCopyPhase.pending && finished == null) ||
            (phase == ImportedCommitCopyPhase.prepared &&
                (observation?.status != ImportedCommitCopyStatus.prepared ||
                    acknowledged != null)) ||
            (phase == ImportedCommitCopyPhase.refused &&
                observation?.status != ImportedCommitCopyStatus.refused)) {
          throw const FormatException();
        }
        if (attempts.isNotEmpty && attempts.last.needsRecovery) {
          throw const FormatException();
        }
        attempts.add(
          ImportedCommitCopyAttempt._(
            request,
            phase,
            observation,
            started,
            finished,
            acknowledged,
          ),
        );
      }
      final canonical = jsonEncode({
        'version': 1,
        'scope': 'imported-commit-copy-history',
        'root': root,
        'attempts': attempts.map((a) => a.toJson()).toList(),
      });
      if (canonical != raw) throw const FormatException();
      return ImportedCommitCopyRecord._(
        root,
        attempts,
        raw,
        sha256.convert(utf8.encode(raw)).toString(),
      );
    } catch (_) {
      throw const FormatException('Saved immutable-copy history is invalid.');
    }
  }
  static DateTime _time(Object? value) {
    if (value is! String) throw const FormatException();
    final at = DateTime.parse(value).toUtc();
    if (at.toIso8601String() != value) throw const FormatException();
    return at;
  }
}
