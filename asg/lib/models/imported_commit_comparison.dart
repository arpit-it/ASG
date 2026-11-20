// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'imported_commit_source_observation.dart';
import 'imported_source_baseline.dart';
import 'imported_source_proposal_record.dart';
import 'project_source_observation.dart';

/// A supplied historical capture versus commit observation, never current disk,
/// authenticated origin, current approval, or a write/copy/execution grant.
final class ImportedCommitComparison {
  ImportedCommitComparison._(
    this._baseline,
    this.request,
    this.observation,
    this.requestDigest,
    this.observationDigest,
    this.recordJson,
    this.digest,
  );
  final ImportedSourceBaseline _baseline;
  final ImportedCommitReadRequest request;
  final ImportedCommitSourceObservation observation;
  final String requestDigest, observationDigest, recordJson, digest;
  ImportedSourceBaselineStatus get status => _baseline.status;
  bool get matched => _baseline.matched;
  List<ImportedSourceBaselineFile> get files => _baseline.files;
  List<String> get changedPaths => _baseline.changedPaths;
  DateTime get observedAt => _baseline.observedAt;
  String? get reason => observation.reason;
  bool get sourceVerified => false;
  static const recordByteLimit = 16 * 1024;

  factory ImportedCommitComparison.compare({
    required ImportedSourceProposalRecord saved,
    required ImportedCommitReadRequest request,
    required ImportedCommitSourceObservation observation,
    required DateTime observedAt,
  }) {
    try {
      if (!observation.matchesRequest(request)) throw const FormatException();
      final observed =
          observation.status == ImportedCommitSourceStatus.observed;
      // Reuse the exact historical-byte comparison rules. A refused object read
      // supplies no fresh working-file data; retain its actual reason separately.
      final supplied = ProjectSourceObservation.fromJson(
        jsonEncode({
          'version': 1,
          'scope': 'project-source-files',
          'status': observed ? 'observed' : 'unavailable',
          'reason': observed ? null : 'source_unavailable',
          'selected_paths': request.selectedPaths,
          'source_verified': false,
          'files': [
            for (final file in observation.files)
              {
                'path': file.source.path,
                'byte_length': file.source.byteLength,
                'sha256': file.source.digest,
                'content_base64': base64Encode(file.source.bytes),
              },
          ],
        }),
      );
      final baseline = ImportedSourceBaseline.compare(
        saved: saved,
        request: ProjectSourceReadRequest(
          root: request.root,
          python: request.python,
          selectedPaths: request.selectedPaths,
        ),
        observation: supplied,
        observedAt: observedAt,
      );
      String hash(Object value) =>
          sha256.convert(utf8.encode(jsonEncode(value))).toString();
      final requestDigest = hash({
        'root': request.root,
        'python': request.python,
        'commit': request.commit,
        'selected_paths': request.selectedPaths,
      });
      final observationDigest = hash({
        'root': observation.root,
        'commit': observation.commit,
        'selected_paths': observation.selectedPaths,
        'status': observation.status.name,
        'reason': observation.reason,
        'tree': observation.tree,
        'manifest_sha256': observation.manifestDigest,
        'manifest_files': observation.manifestFiles,
        'files': [
          for (final file in observation.files)
            {
              'path': file.source.path,
              'mode': file.mode,
              'git_blob': file.gitBlob,
              'sha256': file.source.digest,
              'byte_length': file.source.byteLength,
              'content_base64': base64Encode(file.source.bytes),
            },
        ],
      });
      final record = jsonEncode({
        'version': 1,
        'scope': 'imported-commit-comparison',
        'source_verified': false,
        'working_tree': 'unknown',
        'conflict': 'unknown',
        'root': saved.root,
        'saved_record_sha256': saved.digest,
        'request_sha256': requestDigest,
        'observation_sha256': observationDigest,
        'commit': request.commit,
        'tree': observation.tree,
        'manifest_sha256': observation.manifestDigest,
        'manifest_files': observation.manifestFiles,
        'baseline_sha256': baseline.digest,
        'status': baseline.status.name,
        'reason': observation.reason,
        'observed_at': baseline.observedAt.toIso8601String(),
        'files': [
          for (final file in baseline.files)
            {
              'path': file.path,
              'before_sha256': file.beforeHash,
              'after_sha256': file.afterHash,
              'before_byte_length': file.beforeByteLength,
              'after_byte_length': file.afterByteLength,
              'matches': file.matches,
            },
        ],
      });
      if (utf8.encode(record).length > recordByteLimit) {
        throw const FormatException();
      }
      return ImportedCommitComparison._(
        baseline,
        request,
        observation,
        requestDigest,
        observationDigest,
        record,
        sha256.convert(utf8.encode(record)).toString(),
      );
    } catch (_) {
      throw const FormatException(
        'Invalid immutable commit comparison inputs.',
      );
    }
  }
}
