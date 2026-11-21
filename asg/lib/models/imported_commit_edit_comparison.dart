// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'candidate_comparison.dart';
import 'imported_commit_copy_record.dart';
import 'imported_commit_copy_request.dart';
import 'imported_commit_edit_record.dart';
import 'structured_proposal_json.dart';

/// Historical read intent only. Current durable admission, owned physical reads
/// and cleanup must be established separately; this grants no execution rights.
final class ImportedCommitEditComparisonRequest {
  ImportedCommitEditComparisonRequest._(
    Map<String, Object> data,
    this.requestJson,
  ) : _data = Map.unmodifiable(data),
      digest = sha256.convert(utf8.encode(requestJson)).toString();
  static const byteLimit = 32 * 1024;
  final Map<String, Object> _data;
  final String requestJson, digest;
  String _string(String key) => _data[key]! as String;
  String get root => _string('root');
  String get commit => _string('commit');
  String get originalDestination => _string('original_destination');
  String get proposedDestination => _string('proposed_destination');
  String get originalRun => _string('original_run');
  String get proposedRun => _string('proposed_run');
  int get manifestFiles => _data['manifest_files']! as int;
  String get python => _string('python');
  String get originalCopy => _string('original_copy');
  String get proposedCopy => _string('proposed_copy');
  String get comparisonId => _string('comparison_id');
  String get copyHistoryDigest => _string('copy_history_sha256');
  String get editHistoryDigest => _string('edit_history_sha256');
  String get expectedOriginalFingerprint => _string('original_fingerprint');
  String get expectedProposedFingerprint => _string('proposed_fingerprint');
  String get selectedPath => _string('path');
  bool get authorizesMutation => false;
  bool get authorizesExecution => false;
  bool get sourceVerified => false;

  factory ImportedCommitEditComparisonRequest.create({
    required ImportedCommitCopyRecord copyHistory,
    required ImportedCommitEditRecord editHistory,
    required String python,
    required String comparisonId,
  }) {
    final copies = ImportedCommitCopyRecord.decode(copyHistory.recordJson),
        edits = ImportedCommitEditRecord.decode(editHistory.recordJson);
    final original = copies.lastPrepared, edited = edits.lastPrepared;
    if (copies.needsRecovery ||
        edits.needsRecovery ||
        original == null ||
        edited == null ||
        copies.root != edits.root) {
      throw const FormatException('Confirmed saved copies are required.');
    }
    final copy = original.request,
        receipt = original.observation!,
        change = edited.request,
        output = edited.observation!;
    final labels = jsonDecode(change.requestJson) as Map<String, Object?>;
    final copyReceiptDigest = sha256
        .convert(utf8.encode(receipt.recordJson))
        .toString();
    final selected = copy.selectedFiles.where(
      (f) => f.path == change.selectedPath,
    );
    if (labels['copy_history_sha256'] != copies.digest ||
        labels['copy_request_sha256'] != copy.digest ||
        labels['copy_receipt_sha256'] != copyReceiptDigest ||
        change.sourceCopy != receipt.copyPath ||
        change.root != copies.root ||
        change.commit != copy.commit ||
        change.tree != copy.tree ||
        change.manifestFiles != copy.manifestFiles ||
        labels['manifest_sha256'] != copy.manifestDigest ||
        change.expectedSourceFingerprint != receipt.fingerprint ||
        selected.length != 1 ||
        selected.single.mode != change.mode ||
        selected.single.digest != change.beforeHash ||
        selected.single.gitBlob != labels['before_git_blob'] ||
        selected.single.byteLength != labels['before_byte_length']) {
      throw const FormatException(
        'Saved original and proposal identities differ.',
      );
    }
    return ImportedCommitEditComparisonRequest.restore(
      jsonEncode({
        'version': 1,
        'scope': 'imported-commit-edit-comparison-request',
        'root': copies.root,
        'python': python,
        'comparison_id': comparisonId,
        'commit': copy.commit,
        'tree': copy.tree,
        'original_destination': copy.destination,
        'original_run': receipt.runName,
        'original_copy': receipt.copyPath,
        'proposed_destination': change.destination,
        'proposed_run': output.runName,
        'proposed_copy': output.copyPath,
        'copy_history_sha256': copies.digest,
        'copy_request_sha256': copy.digest,
        'copy_receipt_sha256': copyReceiptDigest,
        'copy_attempt_id': copy.attemptId,
        'edit_history_sha256': edits.digest,
        'edit_request_sha256': change.digest,
        'edit_receipt_sha256': sha256
            .convert(utf8.encode(output.recordJson))
            .toString(),
        'edit_attempt_id': change.attemptId,
        'original_fingerprint': receipt.fingerprint,
        'proposed_fingerprint': output.fingerprint,
        'manifest_files': copy.manifestFiles,
        'path': change.selectedPath,
        'mode': change.mode,
        'before_sha256': change.beforeHash,
        'after_sha256': change.afterHash,
        'before_byte_length': labels['before_byte_length'],
        'after_byte_length': labels['after_byte_length'],
      }),
    );
  }

  /// Schema restoration alone establishes neither a current journal join nor IO.
  factory ImportedCommitEditComparisonRequest.restore(String raw) {
    try {
      if (raw.length > byteLimit || utf8.encode(raw).length > byteLimit) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      final data = jsonDecode(raw);
      const strings = [
        'scope',
        'root',
        'python',
        'comparison_id',
        'commit',
        'tree',
        'original_destination',
        'original_run',
        'original_copy',
        'proposed_destination',
        'proposed_run',
        'proposed_copy',
        'copy_history_sha256',
        'copy_request_sha256',
        'copy_receipt_sha256',
        'copy_attempt_id',
        'edit_history_sha256',
        'edit_request_sha256',
        'edit_receipt_sha256',
        'edit_attempt_id',
        'original_fingerprint',
        'proposed_fingerprint',
        'path',
        'mode',
        'before_sha256',
        'after_sha256',
      ];
      const integers = [
        'version',
        'manifest_files',
        'before_byte_length',
        'after_byte_length',
      ];
      if (data is! Map<String, dynamic> ||
          data.length != strings.length + integers.length ||
          !data.keys.toSet().containsAll([...strings, ...integers]) ||
          strings.any((k) => data[k] is! String) ||
          integers.any((k) => data[k] is! int) ||
          data['version'] != 1 ||
          data['scope'] != 'imported-commit-edit-comparison-request') {
        throw const FormatException();
      }
      bool hex(String key, int count, {bool nonzero = false}) =>
          RegExp('^[a-f0-9]{$count}\$').hasMatch(data[key] as String) &&
          (!nonzero || data[key] != '0' * count);
      if (['commit', 'tree'].any((k) => !hex(k, 40, nonzero: true)) ||
          [
            'comparison_id',
            'copy_attempt_id',
            'edit_attempt_id',
          ].any((k) => !hex(k, 32, nonzero: true)) ||
          [
            'copy_history_sha256',
            'copy_request_sha256',
            'copy_receipt_sha256',
            'edit_history_sha256',
            'edit_request_sha256',
            'edit_receipt_sha256',
            'original_fingerprint',
            'proposed_fingerprint',
            'before_sha256',
            'after_sha256',
          ].any((k) => !hex(k, 64)) ||
          data['before_sha256'] == data['after_sha256'] ||
          data['original_fingerprint'] == data['proposed_fingerprint'] ||
          !RegExp(r'^(lib|test)/[A-Za-z0-9_.\-/]+\.dart$')
              .hasMatch(data['path'] as String) ||
          (data['path'] as String)
              .split('/')
              .any((p) => p.isEmpty || p == '.' || p == '..') ||
          !['100644', '100755'].contains(data['mode']) ||
          data['manifest_files'] < 1 ||
          data['manifest_files'] > 2048 ||
          data['before_byte_length'] < 0 ||
          data['before_byte_length'] > 32768 ||
          data['after_byte_length'] < 1 ||
          data['after_byte_length'] > 16384) {
        throw const FormatException();
      }
      for (final k in [
        'root',
        'python',
        'original_destination',
        'original_copy',
        'proposed_destination',
        'proposed_copy',
      ]) {
        if (!ImportedCommitCopyRequest.validPath(data[k] as String)) {
          throw const FormatException();
        }
      }
      bool inside(String root, String value) =>
          value.toLowerCase() == root.toLowerCase() ||
          value.toLowerCase().startsWith('${root.toLowerCase()}/');
      for (final prefix in ['original', 'proposed']) {
        if (!RegExp(r'^asg-self-candidate-[a-f0-9]{8}$')
                .hasMatch(data['${prefix}_run'] as String) ||
            data['${prefix}_copy'] !=
                '${data['${prefix}_destination']}/${data['${prefix}_run']}/source-${data['commit']}' ||
            inside(
              data['root'] as String,
              data['${prefix}_destination'] as String,
            ) ||
            inside(
              data['${prefix}_destination'] as String,
              data['python'] as String,
            )) {
          throw const FormatException();
        }
      }
      if (data['original_copy'] == data['proposed_copy'] ||
          inside(data['root'] as String, data['python'] as String) ||
          inside(
            path.posix.dirname(data['original_copy'] as String),
            data['proposed_destination'] as String,
          )) {
        throw const FormatException();
      }
      final canonical = <String, Object>{
        for (final k in ['version', ...strings, ...integers.skip(1)])
          k: data[k] as Object,
      };
      return ImportedCommitEditComparisonRequest._(
        canonical,
        jsonEncode(canonical),
      );
    } catch (_) {
      throw const FormatException('Invalid saved-copy comparison request.');
    }
  }
  bool matches(ImportedCommitEditComparisonRequest other) =>
      requestJson == other.requestJson;
}

enum ImportedCommitEditComparisonStatus { matching, changed, refused }

/// Supplied dated observation. Only an owned helper plus final durable fences
/// may establish an application result; this grants no mutation or execution.
final class ImportedCommitEditComparisonObservation {
  ImportedCommitEditComparisonObservation._(
    this.status,
    this.requestDigest,
    this.originalFingerprint,
    this.proposedFingerprint,
    this.originalFiles,
    this.proposedFiles,
    this.originalBytes,
    this.proposedBytes,
    this.selectedMatches,
    this.comparison,
    this.reason,
    this.recordedAt,
    this.recordJson,
  );
  static const responseLimit = 32 * 1024;
  final ImportedCommitEditComparisonStatus status;
  final String requestDigest, recordJson;
  final String? originalFingerprint, proposedFingerprint, reason;
  final int? originalFiles, proposedFiles, originalBytes, proposedBytes;
  final bool? selectedMatches;
  final CandidateComparison? comparison;
  final DateTime recordedAt;
  bool get sourceVerified => false;
  bool get authorizesMutation => false;
  bool get authorizesExecution => false;

  factory ImportedCommitEditComparisonObservation.fromJson(
    String raw, {
    required ImportedCommitEditComparisonRequest request,
  }) {
    try {
      if (raw.length > responseLimit ||
          utf8.encode(raw).length > responseLimit) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      final data = jsonDecode(raw);
      const keys = [
        'version',
        'scope',
        'request_sha256',
        'comparison_id',
        'original_copy',
        'proposed_copy',
        'expected_original_fingerprint',
        'expected_proposed_fingerprint',
        'status',
        'original_fingerprint',
        'proposed_fingerprint',
        'original_files',
        'proposed_files',
        'original_bytes',
        'proposed_bytes',
        'selected_matches',
        'comparison',
        'reason',
        'source_verified',
        'mutation_authorized',
        'execution_authorized',
        'recorded_at',
      ];
      if (data is! Map<String, dynamic> ||
          data.length != keys.length ||
          !data.keys.toSet().containsAll(keys) ||
          data['version'] is! int ||
          data['version'] != 1 ||
          data['scope'] != 'imported-commit-edit-comparison' ||
          data['request_sha256'] != request.digest ||
          data['comparison_id'] != request.comparisonId ||
          data['original_copy'] != request.originalCopy ||
          data['proposed_copy'] != request.proposedCopy ||
          data['expected_original_fingerprint'] !=
              request.expectedOriginalFingerprint ||
          data['expected_proposed_fingerprint'] !=
              request.expectedProposedFingerprint ||
          data['source_verified'] != false ||
          data['mutation_authorized'] != false ||
          data['execution_authorized'] != false ||
          data['recorded_at'] is! String) {
        throw const FormatException();
      }
      final status = ImportedCommitEditComparisonStatus.values.singleWhere(
        (s) => s.name == data['status'],
      );
      CandidateComparison? comparison;
      if (status == ImportedCommitEditComparisonStatus.refused) {
        if (!{'unavailable', 'stopped'}.contains(data['reason']) ||
            [
              'original_fingerprint',
              'proposed_fingerprint',
              'original_files',
              'proposed_files',
              'original_bytes',
              'proposed_bytes',
              'selected_matches',
              'comparison',
            ].any((k) => data[k] != null)) {
          throw const FormatException();
        }
      } else {
        if (data['reason'] != null ||
            data['selected_matches'] is! bool ||
            ['original_fingerprint', 'proposed_fingerprint'].any(
              (k) =>
                  data[k] is! String ||
                  !RegExp(r'^[a-f0-9]{64}$').hasMatch(data[k] as String),
            ) ||
            [
              'original_files',
              'proposed_files',
            ].any((k) => data[k] is! int || data[k] < 0 || data[k] > 2048) ||
            ['original_bytes', 'proposed_bytes'].any(
              (k) =>
                  data[k] is! int || data[k] < 0 || data[k] > 24 * 1024 * 1024,
            )) {
          throw const FormatException();
        }
        comparison = CandidateComparison.decode(jsonEncode(data['comparison']));
        if (comparison.commit != request.commit ||
            comparison.digest != data['proposed_fingerprint']) {
          throw const FormatException();
        }
        final bothMatch =
            data['original_fingerprint'] ==
                request.expectedOriginalFingerprint &&
            data['proposed_fingerprint'] == request.expectedProposedFingerprint;
        if ((status == ImportedCommitEditComparisonStatus.matching) !=
            bothMatch) {
          throw const FormatException();
        }
        if (bothMatch &&
            (data['original_files'] != request.manifestFiles ||
                data['proposed_files'] != request.manifestFiles ||
                data['selected_matches'] != true ||
                comparison.added != 0 ||
                comparison.removed != 0 ||
                comparison.modified != 1 ||
                comparison.executableChanged != 0 ||
                comparison.truncated ||
                comparison.changes.single.path != request.selectedPath ||
                comparison.changes.single.kind !=
                    CandidateChangeKind.modified)) {
          throw const FormatException();
        }
      }
      final at = DateTime.parse(data['recorded_at'] as String).toUtc();
      if (at.toIso8601String() != data['recorded_at']) {
        throw const FormatException();
      }
      return ImportedCommitEditComparisonObservation._(
        status,
        request.digest,
        data['original_fingerprint'] as String?,
        data['proposed_fingerprint'] as String?,
        data['original_files'] as int?,
        data['proposed_files'] as int?,
        data['original_bytes'] as int?,
        data['proposed_bytes'] as int?,
        data['selected_matches'] as bool?,
        comparison,
        data['reason'] as String?,
        at,
        jsonEncode({for (final key in keys) key: data[key]}),
      );
    } catch (_) {
      throw const FormatException(
        'Invalid proposed-copy comparison observation.',
      );
    }
  }
}
