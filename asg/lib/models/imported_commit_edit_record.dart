// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'imported_commit_edit_observation.dart';
import 'imported_commit_edit_request.dart';
import 'structured_proposal_json.dart';

enum ImportedCommitEditPhase { pending, prepared, refused, unconfirmed }

/// Immutable operation history, never restart process ownership or current consent.
final class ImportedCommitEditAttempt {
  const ImportedCommitEditAttempt._(
    this.request,
    this.phase,
    this.observation,
    this.startedAt,
    this.finishedAt,
    this.acknowledgedAt,
  );
  final ImportedCommitEditRequest request;
  final ImportedCommitEditPhase phase;
  final ImportedCommitEditObservation? observation;
  final DateTime startedAt;
  final DateTime? finishedAt, acknowledgedAt;
  bool get needsRecovery =>
      phase != ImportedCommitEditPhase.prepared && acknowledgedAt == null;
  Map<String, Object?> toJson() => {
    'request': request.requestJson,
    'phase': phase.name,
    'observation': observation?.recordJson,
    'startedAt': startedAt.toIso8601String(),
    'finishedAt': finishedAt?.toIso8601String(),
    'acknowledgedAt': acknowledgedAt?.toIso8601String(),
  };
}

final class ImportedCommitEditRecord {
  ImportedCommitEditRecord._(
    this.root,
    List<ImportedCommitEditAttempt> attempts,
    this.recordJson,
    this.digest,
  ) : attempts = List.unmodifiable(attempts);
  static const byteLimit = 1024 * 1024, attemptLimit = 16;
  final String root, recordJson, digest;
  final List<ImportedCommitEditAttempt> attempts;
  ImportedCommitEditAttempt? get latest =>
      attempts.isEmpty ? null : attempts.last;
  bool get needsRecovery => latest?.needsRecovery ?? false;
  bool get canBegin => !needsRecovery && attempts.length < attemptLimit;
  ImportedCommitEditAttempt? get lastPrepared {
    for (final attempt in attempts.reversed) {
      if (attempt.phase == ImportedCommitEditPhase.prepared) return attempt;
    }
    return null;
  }

  factory ImportedCommitEditRecord.empty(String root) => _build(root, []);
  static ImportedCommitEditRecord _build(
    String root,
    List<ImportedCommitEditAttempt> attempts,
  ) => ImportedCommitEditRecord.decode(
    jsonEncode({
      'version': 1,
      'scope': 'imported-commit-edit-history',
      'root': root,
      'attempts': attempts.map((a) => a.toJson()).toList(),
    }),
  );

  ImportedCommitEditRecord begin(
    ImportedCommitEditRequest request,
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
      ImportedCommitEditAttempt._(
        request,
        ImportedCommitEditPhase.pending,
        null,
        at.toUtc(),
        null,
        null,
      ),
    ]);
  }

  ImportedCommitEditRecord settle(
    ImportedCommitEditRequest request,
    ImportedCommitEditObservation? observation,
    DateTime at, {
    bool unconfirmed = false,
  }) {
    final last = latest;
    if (last == null ||
        last.phase != ImportedCommitEditPhase.pending ||
        last.acknowledgedAt != null ||
        !last.request.matches(request) ||
        (!unconfirmed && observation == null)) {
      throw StateError('Copy attempt changed. Reload history.');
    }
    final checked = observation == null
        ? null
        : ImportedCommitEditObservation.fromJson(
            observation.recordJson,
            request: request,
          );
    final phase = unconfirmed
        ? ImportedCommitEditPhase.unconfirmed
        : checked!.status == ImportedCommitEditStatus.prepared
        ? ImportedCommitEditPhase.prepared
        : ImportedCommitEditPhase.refused;
    return _build(root, [
      ...attempts.take(attempts.length - 1),
      ImportedCommitEditAttempt._(
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
  ImportedCommitEditRecord acknowledge(DateTime at) {
    final last = latest;
    if (last == null || !last.needsRecovery) {
      throw StateError('No unresolved copy attempt.');
    }
    return _build(root, [
      ...attempts.take(attempts.length - 1),
      ImportedCommitEditAttempt._(
        last.request,
        last.phase,
        last.observation,
        last.startedAt,
        last.finishedAt,
        at.toUtc(),
      ),
    ]);
  }

  factory ImportedCommitEditRecord.decode(String raw) {
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
          data['scope'] != 'imported-commit-edit-history' ||
          data['root'] is! String ||
          !ImportedCommitEditRequest.validPath(data['root'] as String) ||
          data['attempts'] is! List ||
          (data['attempts'] as List).length > attemptLimit) {
        throw const FormatException();
      }
      final root = data['root'] as String,
          attempts = <ImportedCommitEditAttempt>[];
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
        final request = ImportedCommitEditRequest.restore(
          row['request'] as String,
        );
        if (request.root != root || !ids.add(request.attemptId)) {
          throw const FormatException();
        }
        final phase = ImportedCommitEditPhase.values.singleWhere(
          (v) => v.name == row['phase'],
        );
        final observation = row['observation'] == null
            ? null
            : ImportedCommitEditObservation.fromJson(
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
            (phase == ImportedCommitEditPhase.pending &&
                (finished != null || observation != null)) ||
            (phase != ImportedCommitEditPhase.pending && finished == null) ||
            (phase == ImportedCommitEditPhase.prepared &&
                (observation?.status != ImportedCommitEditStatus.prepared ||
                    acknowledged != null)) ||
            (phase == ImportedCommitEditPhase.refused &&
                observation?.status != ImportedCommitEditStatus.refused)) {
          throw const FormatException();
        }
        if (attempts.isNotEmpty && attempts.last.needsRecovery) {
          throw const FormatException();
        }
        attempts.add(
          ImportedCommitEditAttempt._(
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
        'scope': 'imported-commit-edit-history',
        'root': root,
        'attempts': attempts.map((a) => a.toJson()).toList(),
      });
      if (canonical != raw) throw const FormatException();
      return ImportedCommitEditRecord._(
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
