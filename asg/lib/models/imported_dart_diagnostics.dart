// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'imported_commit_copy_record.dart';
import 'imported_commit_copy_request.dart';
import 'imported_commit_edit_record.dart';
import 'imported_commit_edit_comparison.dart';
import 'structured_proposal_json.dart';

/// Supplied installed-tool labels. Native review must establish actual files,
/// tool hashes and ownership; decoding does not establish trust or permissions.
final class ImportedDartSdkIdentity {
  ImportedDartSdkIdentity._(
    this.root,
    this.version,
    this.runtimeHash,
    this.analyzerHash,
    this.libraryHash,
    this.libraryFiles,
    this.libraryBytes,
    this.recordJson,
  ) : digest = sha256.convert(utf8.encode(recordJson)).toString();
  final String root,
      version,
      runtimeHash,
      analyzerHash,
      libraryHash,
      recordJson,
      digest;
  final int libraryFiles, libraryBytes;
  factory ImportedDartSdkIdentity.create({
    required String root,
    required String version,
    required String runtimeHash,
    required String analyzerHash,
    required String libraryHash,
    required int libraryFiles,
    required int libraryBytes,
  }) => ImportedDartSdkIdentity.restore(
    jsonEncode({
      'root': root,
      'version': version,
      'runtime_sha256': runtimeHash,
      'analyzer_sha256': analyzerHash,
      'library_manifest_sha256': libraryHash,
      'library_files': libraryFiles,
      'library_bytes': libraryBytes,
    }),
  );
  factory ImportedDartSdkIdentity.restore(String raw) {
    try {
      if (raw.length > 8192 || utf8.encode(raw).length > 8192) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      final d = jsonDecode(raw);
      const strings = [
        'root',
        'version',
        'runtime_sha256',
        'analyzer_sha256',
        'library_manifest_sha256',
      ];
      const integers = ['library_files', 'library_bytes'];
      const keys = [...strings, ...integers];
      if (d is! Map<String, dynamic> ||
          d.length != keys.length ||
          !d.keys.toSet().containsAll(keys) ||
          strings.any((k) => d[k] is! String) ||
          integers.any((k) => d[k] is! int) ||
          d['library_files'] < 1 ||
          d['library_files'] > 2048 ||
          d['library_bytes'] < 0 ||
          d['library_bytes'] > 128 * 1024 * 1024 ||
          !ImportedCommitCopyRequest.validPath(d['root'] as String) ||
          (d['version'] as String).length > 128 ||
          !RegExp(r'^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.\-]+)?$')
              .hasMatch(d['version'] as String) ||
          [
            'runtime_sha256',
            'analyzer_sha256',
            'library_manifest_sha256',
          ].any((k) => !RegExp(r'^[a-f0-9]{64}$').hasMatch(d[k] as String))) {
        throw const FormatException();
      }
      return ImportedDartSdkIdentity._(
        d['root'] as String,
        d['version'] as String,
        d['runtime_sha256'] as String,
        d['analyzer_sha256'] as String,
        d['library_manifest_sha256'] as String,
        d['library_files'] as int,
        d['library_bytes'] as int,
        jsonEncode({for (final k in keys) k: d[k]}),
      );
    } catch (_) {
      throw const FormatException('Invalid installed Dart SDK identity.');
    }
  }
}

/// Isolated file-analysis intent only. Supplied comparison and SDK labels are
/// not current consent, physical observation or project execution authority.
final class ImportedDartDiagnosticsRequest {
  ImportedDartDiagnosticsRequest._(
    this.comparison,
    this.sdk,
    this.comparisonReceiptDigest,
    this.replacement,
    this.runId,
    this.requestJson,
  ) : digest = sha256.convert(utf8.encode(requestJson)).toString();
  static const byteLimit = 64 * 1024;
  final ImportedCommitEditComparisonRequest comparison;
  final ImportedDartSdkIdentity sdk;
  final String comparisonReceiptDigest, replacement, runId, requestJson, digest;
  String get root => comparison.root;
  String get python => comparison.python;
  String get selectedPath => comparison.selectedPath;
  bool get verifiesProject => false;
  bool get authorizesProjectExecution => false;
  bool get authorizesMutation => false;
  factory ImportedDartDiagnosticsRequest.create({
    required ImportedCommitCopyRecord copyHistory,
    required ImportedCommitEditRecord editHistory,
    required ImportedCommitEditComparisonRequest compared,
    required ImportedCommitEditComparisonObservation observation,
    required ImportedDartSdkIdentity sdk,
    required String python,
    required String runId,
  }) {
    final rebuilt = ImportedCommitEditComparisonRequest.create(
      copyHistory: copyHistory,
      editHistory: editHistory,
      python: python,
      comparisonId: compared.comparisonId,
    );
    final observed = ImportedCommitEditComparisonObservation.fromJson(
      observation.recordJson,
      request: compared,
    );
    if (!rebuilt.matches(compared) ||
        observed.status != ImportedCommitEditComparisonStatus.matching) {
      throw const FormatException('A current matching comparison is required.');
    }
    final edits = ImportedCommitEditRecord.decode(editHistory.recordJson);
    return ImportedDartDiagnosticsRequest.restore(
      jsonEncode({
        'version': 1,
        'scope': 'imported-dart-diagnostics-request',
        'comparison_request': rebuilt.requestJson,
        'comparison_receipt_sha256': sha256
            .convert(utf8.encode(observed.recordJson))
            .toString(),
        'sdk_identity': sdk.recordJson,
        'replacement': edits.lastPrepared!.request.replacement,
        'run_id': runId,
      }),
    );
  }

  /// Historical decoding. Only a fresh owned controller/store/native admission
  /// may establish the physical read and reviewed SDK represented by this data.
  factory ImportedDartDiagnosticsRequest.restore(String raw) {
    try {
      if (raw.length > byteLimit || utf8.encode(raw).length > byteLimit) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      final d = jsonDecode(raw);
      const strings = [
        'scope',
        'comparison_request',
        'comparison_receipt_sha256',
        'sdk_identity',
        'replacement',
        'run_id',
      ];
      if (d is! Map<String, dynamic> ||
          d.length != strings.length + 1 ||
          !d.keys.toSet().containsAll(['version', ...strings]) ||
          d['version'] is! int ||
          d['version'] != 1 ||
          d['scope'] != 'imported-dart-diagnostics-request' ||
          strings.any((k) => d[k] is! String) ||
          !RegExp(r'^[a-f0-9]{64}$')
              .hasMatch(d['comparison_receipt_sha256'] as String) ||
          !RegExp(r'^[a-f0-9]{32}$').hasMatch(d['run_id'] as String) ||
          d['run_id'] == '0' * 32) {
        throw const FormatException();
      }
      final comparison = ImportedCommitEditComparisonRequest.restore(
            d['comparison_request'] as String,
          ),
          sdk = ImportedDartSdkIdentity.restore(d['sdk_identity'] as String),
          text = d['replacement'] as String;
      if (comparison.requestJson != d['comparison_request'] ||
          sdk.recordJson != d['sdk_identity']) {
        throw const FormatException();
      }
      final labels = jsonDecode(comparison.requestJson) as Map<String, dynamic>,
          bytes = utf8.encode(text);
      if (bytes.isEmpty ||
          bytes.length > 16384 ||
          // Prefix prevents the decoder from stripping a literal UTF-8 BOM.
          utf8.decode([0x20, ...bytes]).substring(1) != text ||
          bytes.length != labels['after_byte_length'] ||
          sha256.convert(bytes).toString() != labels['after_sha256']) {
        throw const FormatException();
      }
      bool inside(String root, String value) =>
          value.toLowerCase() == root.toLowerCase() ||
          value.toLowerCase().startsWith('${root.toLowerCase()}/');
      for (final protected in [
        comparison.root,
        comparison.originalDestination,
        comparison.proposedDestination,
        comparison.python,
      ]) {
        if (inside(protected, sdk.root) || inside(sdk.root, protected)) {
          throw const FormatException();
        }
      }
      final canonical = jsonEncode({
        'version': 1,
        for (final k in strings) k: d[k],
      });
      return ImportedDartDiagnosticsRequest._(
        comparison,
        sdk,
        d['comparison_receipt_sha256'] as String,
        text,
        d['run_id'] as String,
        canonical,
      );
    } catch (_) {
      throw const FormatException('Invalid isolated Dart diagnostics request.');
    }
  }
  bool matches(ImportedDartDiagnosticsRequest other) =>
      requestJson == other.requestJson;
}

enum ImportedDartDiagnosticsStatus {
  clean,
  issues,
  incomplete,
  unavailable,
  stopped,
}

final class ImportedDartDiagnostic {
  const ImportedDartDiagnostic._(
    this.severity,
    this.type,
    this.code,
    this.message,
    this.offset,
    this.length,
    this.line,
    this.column,
  );
  final String severity, type, code, message;
  final int offset, length, line, column;
}

/// Dated isolated-file evidence, never whole-project verification or authority.
final class ImportedDartDiagnosticsObservation {
  ImportedDartDiagnosticsObservation._(
    this.status,
    this.requestDigest,
    this.reason,
    this.protocolVersion,
    List<ImportedDartDiagnostic> diagnostics,
    this.recordedAt,
    this.recordJson,
  ) : diagnostics = List.unmodifiable(diagnostics);
  static const responseLimit = 32 * 1024;
  final ImportedDartDiagnosticsStatus status;
  final String requestDigest, recordJson;
  final String? reason, protocolVersion;
  final List<ImportedDartDiagnostic> diagnostics;
  final DateTime recordedAt;
  bool get verifiesProject => false;
  bool get authorizesProjectExecution => false;
  bool get authorizesMutation => false;
  bool get completed => [
    ImportedDartDiagnosticsStatus.clean,
    ImportedDartDiagnosticsStatus.issues,
    ImportedDartDiagnosticsStatus.incomplete,
  ].contains(status);
  factory ImportedDartDiagnosticsObservation.fromJson(
    String raw, {
    required ImportedDartDiagnosticsRequest request,
  }) {
    try {
      if (raw.length > responseLimit ||
          utf8.encode(raw).length > responseLimit) {
        throw const FormatException();
      }
      rejectDuplicateJsonMembers(raw);
      final d = jsonDecode(raw);
      const keys = [
        'version',
        'scope',
        'request_sha256',
        'run_id',
        'comparison_request_sha256',
        'sdk_identity_sha256',
        'selected_path',
        'source_sha256',
        'status',
        'reason',
        'protocol_version',
        'diagnostics',
        'source_verified',
        'project_verified',
        'mutation_authorized',
        'execution_authorized',
        'recorded_at',
      ];
      if (d is! Map<String, dynamic> ||
          d.length != keys.length ||
          !d.keys.toSet().containsAll(keys) ||
          d['version'] is! int ||
          d['version'] != 1 ||
          d['scope'] != 'imported-dart-diagnostics' ||
          d['request_sha256'] != request.digest ||
          d['run_id'] != request.runId ||
          d['comparison_request_sha256'] != request.comparison.digest ||
          d['sdk_identity_sha256'] != request.sdk.digest ||
          d['selected_path'] != request.selectedPath ||
          d['source_sha256'] !=
              sha256.convert(utf8.encode(request.replacement)).toString() ||
          d['source_verified'] != false ||
          d['project_verified'] != false ||
          d['mutation_authorized'] != false ||
          d['execution_authorized'] != false ||
          d['diagnostics'] is! List ||
          (d['diagnostics'] as List).length > 100 ||
          d['recorded_at'] is! String) {
        throw const FormatException();
      }
      final status = ImportedDartDiagnosticsStatus.values.singleWhere(
        (s) => s.name == d['status'],
      );
      final completed = [
        ImportedDartDiagnosticsStatus.clean,
        ImportedDartDiagnosticsStatus.issues,
        ImportedDartDiagnosticsStatus.incomplete,
      ].contains(status);
      final findings = <ImportedDartDiagnostic>[];
      for (final item in d['diagnostics'] as List) {
        const strings = ['severity', 'type', 'code', 'message'];
        const integers = ['offset', 'length', 'line', 'column'];
        if (item is! Map<String, dynamic> ||
            item.length != 8 ||
            !item.keys.toSet().containsAll([...strings, ...integers]) ||
            strings.any((k) => item[k] is! String) ||
            integers.any((k) => item[k] is! int) ||
            !['ERROR', 'WARNING', 'INFO'].contains(item['severity']) ||
            !RegExp(r'^[A-Z_]{1,80}$').hasMatch(item['type'] as String) ||
            !RegExp(r'^[a-z0-9_]{1,120}$').hasMatch(item['code'] as String) ||
            (item['message'] as String).isEmpty ||
            (item['message'] as String).length > 2048 ||
            (item['message'] as String).contains('\u0000') ||
            item['offset'] < 0 ||
            item['length'] < 0 ||
            item['offset'] + item['length'] > request.replacement.length ||
            item['line'] < 1 ||
            item['column'] < 1 ||
            item['line'] > request.replacement.length + 1 ||
            item['column'] > request.replacement.length + 1) {
          throw const FormatException();
        }
        findings.add(
          ImportedDartDiagnostic._(
            item['severity'] as String,
            item['type'] as String,
            item['code'] as String,
            item['message'] as String,
            item['offset'] as int,
            item['length'] as int,
            item['line'] as int,
            item['column'] as int,
          ),
        );
      }
      final incomplete = findings.any((f) => f.code.startsWith('uri_'));
      if (completed) {
        if (d['reason'] != null ||
            d['protocol_version'] != '1.40.1' ||
            (status == ImportedDartDiagnosticsStatus.clean) !=
                findings.isEmpty ||
            (status == ImportedDartDiagnosticsStatus.incomplete) !=
                incomplete) {
          throw const FormatException();
        }
      } else {
        if (findings.isNotEmpty ||
            d['protocol_version'] != null ||
            (status == ImportedDartDiagnosticsStatus.stopped
                ? d['reason'] != 'stopped'
                : !{
                    'unavailable',
                    'input_changed',
                    'protocol',
                    'output_limit',
                    'deadline',
                    'unsupported_sdk',
                    'cleanup',
                  }.contains(d['reason']))) {
          throw const FormatException();
        }
      }
      final at = DateTime.parse(d['recorded_at'] as String).toUtc();
      if (at.toIso8601String() != d['recorded_at']) {
        throw const FormatException();
      }
      return ImportedDartDiagnosticsObservation._(
        status,
        request.digest,
        d['reason'] as String?,
        d['protocol_version'] as String?,
        findings,
        at,
        jsonEncode({for (final k in keys) k: d[k]}),
      );
    } catch (_) {
      throw const FormatException(
        'Invalid isolated Dart diagnostics observation.',
      );
    }
  }
}
