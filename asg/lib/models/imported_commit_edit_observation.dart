// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'imported_commit_edit_request.dart';
import 'imported_commit_copy_request.dart';
import 'structured_proposal_json.dart';

enum ImportedCommitEditStatus { prepared, refused }

/// Supplied outcome, not current consent, source trust or execution permission.
final class ImportedCommitEditObservation {
  ImportedCommitEditObservation._(
    this.requestDigest,
    this.status,
    this.reason,
    this.runName,
    this.copyPath,
    this.fingerprint,
    this.files,
    this.bytes,
    this.recordedAt,
    this.recordJson,
  );
  static const responseLimit = 32 * 1024;
  final String requestDigest, recordJson;
  final ImportedCommitEditStatus status;
  final String? reason, runName, copyPath, fingerprint;
  final int? files, bytes;
  final DateTime recordedAt;
  bool get sourceVerified => false;
  bool get authorizesExecution => false;
  String? reportedRun(ImportedCommitEditRequest request) =>
      request.digest == requestDigest && runName != null
      ? '${request.destination}/$runName'
      : null;
  factory ImportedCommitEditObservation.fromJson(
    String raw, {
    required ImportedCommitEditRequest request,
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
        'attempt_id',
        'root',
        'source_copy',
        'destination',
        'commit',
        'expected_source_fingerprint',
        'selected_path',
        'after_sha256',
        'status',
        'reason',
        'run_name',
        'copy_path',
        'fingerprint',
        'files',
        'bytes',
        'source_verified',
        'execution_authorized',
        'recorded_at',
      ];
      if (data is! Map<String, dynamic> ||
          data.length != keys.length ||
          !data.keys.toSet().containsAll(keys) ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['scope'] != 'imported-commit-edit' ||
          data['request_sha256'] != request.digest ||
          data['attempt_id'] != request.attemptId ||
          data['root'] != request.root ||
          data['source_copy'] != request.sourceCopy ||
          data['destination'] != request.destination ||
          data['commit'] != request.commit ||
          data['expected_source_fingerprint'] !=
              request.expectedSourceFingerprint ||
          data['selected_path'] != request.selectedPath ||
          data['after_sha256'] != request.afterHash ||
          data['source_verified'] != false ||
          data['execution_authorized'] != false ||
          data['recorded_at'] is! String) {
        throw const FormatException();
      }
      final run = data['run_name'];
      if (run != null &&
          (run is! String ||
              !RegExp(r'^asg-self-candidate-[a-f0-9]{8}$').hasMatch(run))) {
        throw const FormatException();
      }
      final prepared = data['status'] == 'prepared';
      if (prepared) {
        if (run == null ||
            data['reason'] != null ||
            data['copy_path'] is! String ||
            !ImportedCommitCopyRequest.validPath(data['copy_path'] as String) ||
            data['copy_path'] !=
                '${request.destination}/$run/source-${request.commit}' ||
            data['fingerprint'] is! String ||
            !RegExp(r'^[a-f0-9]{64}$')
                .hasMatch(data['fingerprint'] as String) ||
            data['fingerprint'] == request.expectedSourceFingerprint ||
            data['files'] is! int ||
            data['files'] != request.manifestFiles ||
            data['bytes'] is! int ||
            data['bytes'] < request.afterByteLength ||
            data['bytes'] > 24 * 1024 * 1024) {
          throw const FormatException();
        }
      } else if (data['status'] != 'refused' ||
          !{
            'unavailable',
            'input_changed',
            'stopped',
          }.contains(data['reason']) ||
          data['copy_path'] != null ||
          data['fingerprint'] != null ||
          data['files'] != null ||
          data['bytes'] != null) {
        throw const FormatException();
      }
      final at = DateTime.parse(data['recorded_at'] as String).toUtc();
      if (at.toIso8601String() != data['recorded_at']) {
        throw const FormatException();
      }
      final canonical = jsonEncode({for (final key in keys) key: data[key]});
      return ImportedCommitEditObservation._(
        request.digest,
        prepared
            ? ImportedCommitEditStatus.prepared
            : ImportedCommitEditStatus.refused,
        data['reason'] as String?,
        run as String?,
        data['copy_path'] as String?,
        data['fingerprint'] as String?,
        data['files'] as int?,
        data['bytes'] as int?,
        at,
        canonical,
      );
    } catch (_) {
      throw const FormatException(
        'Invalid isolated proposed-copy observation.',
      );
    }
  }
}
