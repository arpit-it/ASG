// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'imported_commit_copy_record.dart';
import 'imported_commit_copy_request.dart';
import 'imported_commit_source_observation.dart';
import 'structured_proposal_json.dart';

/// Supplied read-only intent, not current app admission, disk proof or authority.
final class ImportedCommitCopyRecheckRequest {
  ImportedCommitCopyRecheckRequest._(Map<String, Object> data, this.requestJson)
    : _data = Map.unmodifiable(data),
      digest = sha256.convert(utf8.encode(requestJson)).toString();
  static const byteLimit = 32 * 1024;
  final Map<String, Object> _data;
  final String requestJson, digest;
  String _value(String key) => _data[key]! as String;
  String get root => _value('root');
  String get python => _value('python');
  String get destination => _value('destination');
  String get copyPath => _value('copy_path');
  String get runName => _value('run_name');
  String get commit => _value('commit');
  String get tree => _value('tree');
  String get expectedFingerprint => _value('expected_fingerprint');
  String get historyDigest => _value('copy_history_sha256');
  String get copyRequestDigest => _value('copy_request_sha256');
  String get copyReceiptDigest => _value('copy_receipt_sha256');
  String get copyAttemptId => _value('copy_attempt_id');
  String get recheckId => _value('recheck_id');
  bool get authorizesMutation => false;
  bool get sourceVerified => false;

  factory ImportedCommitCopyRecheckRequest.create({
    required ImportedCommitCopyRecord history,
    required String python,
    required String recheckId,
  }) {
    final checked = ImportedCommitCopyRecord.decode(history.recordJson);
    final prepared = checked.lastPrepared;
    if (checked.needsRecovery || prepared == null) {
      throw const FormatException(
        'A confirmed copy without unresolved recovery is required.',
      );
    }
    final original = prepared.request, receipt = prepared.observation!;
    return ImportedCommitCopyRecheckRequest.restore(
      jsonEncode({
        'version': 1,
        'scope': 'imported-commit-copy-recheck-request',
        'root': checked.root,
        'python': python,
        'destination': original.destination,
        'copy_path': receipt.copyPath,
        'run_name': receipt.runName,
        'commit': original.commit,
        'tree': original.tree,
        'expected_fingerprint': receipt.fingerprint,
        'copy_history_sha256': checked.digest,
        'copy_request_sha256': original.digest,
        'copy_receipt_sha256': sha256
            .convert(utf8.encode(receipt.recordJson))
            .toString(),
        'copy_attempt_id': original.attemptId,
        'recheck_id': recheckId,
      }),
    );
  }

  /// Historical decoding only. Rebuild from exact current history/runtime at
  /// application admission; a restored digest label cannot establish consent.
  factory ImportedCommitCopyRecheckRequest.restore(String raw) {
    try {
      if (raw.length > byteLimit || utf8.encode(raw).length > byteLimit) {
        throw const FormatException();
      }
      final data = jsonDecode(raw);
      rejectDuplicateJsonMembers(raw);
      const keys = [
        'version',
        'scope',
        'root',
        'python',
        'destination',
        'copy_path',
        'run_name',
        'commit',
        'tree',
        'expected_fingerprint',
        'copy_history_sha256',
        'copy_request_sha256',
        'copy_receipt_sha256',
        'copy_attempt_id',
        'recheck_id',
      ];
      if (data is! Map<String, dynamic> ||
          data.length != keys.length ||
          !data.keys.toSet().containsAll(keys) ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['scope'] != 'imported-commit-copy-recheck-request' ||
          keys.skip(2).any((key) => data[key] is! String)) {
        throw const FormatException();
      }
      String value(String key) => data[key] as String;
      if (![
            'root',
            'python',
            'destination',
            'copy_path',
          ].every((key) => ImportedCommitCopyRequest.validPath(value(key))) ||
          ![
            'commit',
            'tree',
          ].every((key) => ImportedCommitReadRequest.validCommit(value(key))) ||
          ![
            'expected_fingerprint',
            'copy_history_sha256',
            'copy_request_sha256',
            'copy_receipt_sha256',
          ].every((key) => RegExp(r'^[a-f0-9]{64}$').hasMatch(value(key))) ||
          !['copy_attempt_id', 'recheck_id'].every(
            (key) =>
                RegExp(r'^[a-f0-9]{32}$').hasMatch(value(key)) &&
                value(key) != '0' * 32,
          ) ||
          !RegExp(r'^asg-self-candidate-[a-f0-9]{8}$')
              .hasMatch(value('run_name')) ||
          value('copy_path') !=
              '${value('destination')}/${value('run_name')}/source-${value('commit')}' ||
          _inside(value('root'), value('destination')) ||
          _inside(value('root'), value('python')) ||
          _inside(value('destination'), value('python'))) {
        throw const FormatException();
      }
      final canonical = <String, Object>{
        for (final key in keys) key: data[key] as Object,
      };
      if (jsonEncode(canonical) != raw) throw const FormatException();
      return ImportedCommitCopyRecheckRequest._(canonical, raw);
    } catch (_) {
      throw const FormatException('Invalid original-copy recheck request.');
    }
  }
  bool matches(ImportedCommitCopyRecheckRequest other) =>
      requestJson == other.requestJson;
  static bool _inside(String root, String value) =>
      path.posix.equals(root.toLowerCase(), value.toLowerCase()) ||
      path.posix.isWithin(root.toLowerCase(), value.toLowerCase());
}

enum ImportedCommitCopyRecheckStatus { matching, changed, refused }

/// Dated supplied observation. Never a durable approval or future disk proof.
final class ImportedCommitCopyRecheckObservation {
  ImportedCommitCopyRecheckObservation._({
    required this.status,
    required this.requestDigest,
    required this.copyPath,
    required this.expectedFingerprint,
    required this.observedFingerprint,
    required this.files,
    required this.bytes,
    required this.reason,
    required this.recordedAt,
    required this.recordJson,
  });
  static const responseLimit = 32 * 1024;
  final ImportedCommitCopyRecheckStatus status;
  final String requestDigest, copyPath, expectedFingerprint, recordJson;
  final String? observedFingerprint, reason;
  final int? files, bytes;
  final DateTime recordedAt;
  bool get authorizesMutation => false;
  bool get sourceVerified => false;
  factory ImportedCommitCopyRecheckObservation.fromJson(
    String raw, {
    required ImportedCommitCopyRecheckRequest request,
  }) {
    try {
      if (raw.length > responseLimit ||
          utf8.encode(raw).length > responseLimit) {
        throw const FormatException();
      }
      final data = jsonDecode(raw);
      rejectDuplicateJsonMembers(raw);
      const keys = [
        'version',
        'scope',
        'request_sha256',
        'recheck_id',
        'copy_path',
        'expected_fingerprint',
        'status',
        'observed_fingerprint',
        'files',
        'bytes',
        'reason',
        'source_verified',
        'mutation_authorized',
        'recorded_at',
      ];
      if (data is! Map<String, dynamic> ||
          data.length != keys.length ||
          !data.keys.toSet().containsAll(keys) ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['scope'] != 'imported-commit-copy-recheck' ||
          data['request_sha256'] != request.digest ||
          data['recheck_id'] != request.recheckId ||
          data['copy_path'] != request.copyPath ||
          data['expected_fingerprint'] != request.expectedFingerprint ||
          data['source_verified'] != false ||
          data['mutation_authorized'] != false ||
          data['recorded_at'] is! String) {
        throw const FormatException();
      }
      final status = ImportedCommitCopyRecheckStatus.values.singleWhere(
        (s) => s.name == data['status'],
      );
      if (status == ImportedCommitCopyRecheckStatus.refused) {
        if (!{'unavailable', 'stopped'}.contains(data['reason']) ||
            data['observed_fingerprint'] != null ||
            data['files'] != null ||
            data['bytes'] != null) {
          throw const FormatException();
        }
      } else {
        if (data['reason'] != null ||
            data['observed_fingerprint'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$')
                .hasMatch(data['observed_fingerprint'] as String) ||
            data['files'] is! int ||
            data['files'] < 1 ||
            data['files'] > 2048 ||
            data['bytes'] is! int ||
            data['bytes'] < 0 ||
            data['bytes'] > 24 * 1024 * 1024 ||
            (status == ImportedCommitCopyRecheckStatus.matching) !=
                (data['observed_fingerprint'] == request.expectedFingerprint)) {
          throw const FormatException();
        }
      }
      final at = DateTime.parse(data['recorded_at'] as String).toUtc();
      if (at.toIso8601String() != data['recorded_at']) {
        throw const FormatException();
      }
      final canonical = jsonEncode({for (final key in keys) key: data[key]});
      return ImportedCommitCopyRecheckObservation._(
        status: status,
        requestDigest: request.digest,
        copyPath: request.copyPath,
        expectedFingerprint: request.expectedFingerprint,
        observedFingerprint: data['observed_fingerprint'] as String?,
        files: data['files'] as int?,
        bytes: data['bytes'] as int?,
        reason: data['reason'] as String?,
        recordedAt: at,
        recordJson: canonical,
      );
    } catch (_) {
      throw const FormatException('Invalid original-copy recheck observation.');
    }
  }
}
