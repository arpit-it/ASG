// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'imported_commit_copy_request.dart';
import 'structured_proposal_json.dart';

enum ImportedCommitCopyStatus { prepared, refused }

/// Supplied, request-bound helper data. Decoding does not prove native dispatch,
/// current disk identity, current consent or permission to run the copied files.
final class ImportedCommitCopyObservation {
  ImportedCommitCopyObservation._({
    required this.status,
    required this.reason,
    required this.requestDigest,
    required this.runName,
    required this.copyPath,
    required this.fingerprint,
    required this.files,
    required this.bytes,
    required this.recordedAt,
    required this.recordJson,
  });
  static const responseLimit = 32 * 1024;
  final ImportedCommitCopyStatus status;
  final String? reason, runName, copyPath, fingerprint;
  final String requestDigest, recordJson;
  final int? files, bytes;
  final DateTime recordedAt;
  bool get sourceVerified => false;
  bool get appliesReplacement => false;
  String get workingTree => 'unknown';
  String get conflict => 'unknown';
  String? reportedRun(ImportedCommitCopyRequest request) =>
      request.digest == requestDigest && runName != null
      ? '${request.destination}/$runName'
      : null;

  factory ImportedCommitCopyObservation.fromJson(
    String raw, {
    required ImportedCommitCopyRequest request,
  }) {
    try {
      if (raw.length > responseLimit ||
          utf8.encode(raw).length > responseLimit) {
        throw const FormatException();
      }
      final data = jsonDecode(raw);
      rejectDuplicateJsonMembers(raw);
      const keys = {
        'version',
        'scope',
        'request_sha256',
        'attempt_id',
        'root',
        'destination',
        'commit',
        'tree',
        'manifest_sha256',
        'manifest_files',
        'status',
        'reason',
        'run_name',
        'copy_path',
        'fingerprint',
        'files',
        'bytes',
        'source_verified',
        'working_tree',
        'conflict',
        'recorded_at',
      };
      if (data is! Map<String, dynamic> ||
          data.length != keys.length ||
          !data.keys.toSet().containsAll(keys) ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['scope'] != 'imported-commit-copy' ||
          data['request_sha256'] != request.digest ||
          data['attempt_id'] != request.attemptId ||
          data['root'] != request.root ||
          data['destination'] != request.destination ||
          data['commit'] != request.commit ||
          data['tree'] != request.tree ||
          data['manifest_sha256'] != request.manifestDigest ||
          data['manifest_files'] is! int ||
          data['manifest_files'] != request.manifestFiles ||
          data['source_verified'] != false ||
          data['working_tree'] != 'unknown' ||
          data['conflict'] != 'unknown' ||
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
            data['files'] is! int ||
            data['files'] != request.manifestFiles ||
            data['bytes'] is! int ||
            data['bytes'] <
                request.selectedFiles.fold<int>(
                  0,
                  (sum, f) => sum + f.byteLength,
                ) ||
            data['bytes'] > 24 * 1024 * 1024) {
          throw const FormatException();
        }
      } else if (data['status'] != 'refused' ||
          !{
            'input_changed',
            'copy_unavailable',
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
      final canonical = jsonEncode({
        'version': 1,
        'scope': 'imported-commit-copy',
        'request_sha256': request.digest,
        'attempt_id': request.attemptId,
        'root': request.root,
        'destination': request.destination,
        'commit': request.commit,
        'tree': request.tree,
        'manifest_sha256': request.manifestDigest,
        'manifest_files': request.manifestFiles,
        'status': prepared ? 'prepared' : 'refused',
        'reason': data['reason'],
        'run_name': run,
        'copy_path': data['copy_path'],
        'fingerprint': data['fingerprint'],
        'files': data['files'],
        'bytes': data['bytes'],
        'source_verified': false,
        'working_tree': 'unknown',
        'conflict': 'unknown',
        'recorded_at': at.toIso8601String(),
      });
      return ImportedCommitCopyObservation._(
        status: prepared
            ? ImportedCommitCopyStatus.prepared
            : ImportedCommitCopyStatus.refused,
        reason: data['reason'] as String?,
        requestDigest: request.digest,
        runName: run as String?,
        copyPath: data['copy_path'] as String?,
        fingerprint: data['fingerprint'] as String?,
        files: data['files'] as int?,
        bytes: data['bytes'] as int?,
        recordedAt: at,
        recordJson: canonical,
      );
    } catch (_) {
      throw const FormatException('Invalid immutable baseline-copy result.');
    }
  }
}
