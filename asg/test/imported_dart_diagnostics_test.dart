// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_dart_diagnostics.dart';
import 'package:asg/models/imported_commit_edit_record.dart';

import 'imported_commit_proposal_record_test.dart' show historicalRecord;
import 'imported_commit_edit_request_test.dart' show editBasis;
import 'imported_commit_edit_comparison_controller_test.dart'
    show sampleComparisonRequest, comparisonResult, preparedEdits;

void main() {
  ImportedDartSdkIdentity sdk({
    String root = '/trusted/dart-sdk',
    String runtime = 'a',
  }) => ImportedDartSdkIdentity.create(
    root: root,
    version: '3.10.0',
    runtimeHash: runtime * 64,
    analyzerHash: 'b' * 64,
    libraryHash: 'c' * 64,
    libraryFiles: 1,
    libraryBytes: 100,
  );
  ImportedDartDiagnosticsRequest request({
    String status = 'matching',
    String python = '/trusted/current-python',
    String run = 'e',
    ImportedDartSdkIdentity? tools,
    ImportedCommitEditRecord? edits,
  }) {
    final compared = sampleComparisonRequest();
    return ImportedDartDiagnosticsRequest.create(
      copyHistory: editBasis(historicalRecord()).history,
      editHistory: edits ?? preparedEdits(),
      compared: compared,
      observation: comparisonResult(compared, status: status),
      sdk: tools ?? sdk(),
      python: python,
      runId: run * 32,
    );
  }

  test('isolated intent binds exact compared bytes and reviewed tool identity without project authority', () {
    final r = request();
    expect(r.comparison.matches(sampleComparisonRequest()), true);
    expect(r.replacement, preparedEdits().lastPrepared!.request.replacement);
    expect(
      r.comparisonReceiptDigest,
      sha256
          .convert(
            utf8.encode(comparisonResult(sampleComparisonRequest()).recordJson),
          )
          .toString(),
    );
    expect(r.sdk.runtimeHash, 'a' * 64);
    expect(r.sdk.analyzerHash, 'b' * 64);
    expect(r.sdk.root, '/trusted/dart-sdk');
    expect(r.verifiesProject, false);
    expect(r.authorizesProjectExecution, false);
    expect(r.authorizesMutation, false);
    expect(
      ImportedDartDiagnosticsRequest.restore(r.requestJson).matches(r),
      true,
    );
  });
  test('changed refused stale runtime or unresolved historical input cannot borrow matching evidence', () {
    for (final status in ['changed', 'refused']) {
      expect(() => request(status: status), throwsFormatException);
    }
    expect(
      () => request(python: '/trusted/changed-python'),
      throwsFormatException,
    );
    expect(
      () => request(edits: ImportedCommitEditRecord.empty('/project')),
      throwsFormatException,
    );
    expect(() => request(run: '0'), throwsFormatException);
  });
  test('SDK identities cannot alias source, either saved destination or interpreter', () {
    final c = sampleComparisonRequest();
    for (final root in [
      c.root,
      '${c.root}/sdk',
      c.originalDestination,
      '${c.proposedCopy}/sdk',
      '/trusted',
      c.python,
    ]) {
      expect(() => request(tools: sdk(root: root)), throwsFormatException);
    }
  });
  test('new SDK labels or run nonce require a distinct request identity', () {
    final r = request();
    expect(request(tools: sdk(runtime: 'c')).matches(r), false);
    expect(request(run: 'f').matches(r), false);
  });
  test('SDK metadata rejects malformed paths versions hashes duplicate and unknown keys', () {
    final original = jsonDecode(sdk().recordJson) as Map<String, dynamic>;
    for (final change in <Map<String, Object?>>[
      {'root': '/alias/../sdk'},
      {'root': '/Stable.app/sdk'},
      {'version': 'latest'},
      {'version': true},
      {'runtime_sha256': 'bad'},
      {'library_manifest_sha256': 'bad'},
      {'library_files': 2049},
      {'library_files': true},
      {'library_bytes': 129 * 1024 * 1024},
      {'extra': true},
    ]) {
      expect(
        () => ImportedDartSdkIdentity.restore(
          jsonEncode({...original, ...change}),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => ImportedDartSdkIdentity.restore(
        sdk().recordJson.replaceFirst('{', '{"root":"/foreign",'),
      ),
      throwsFormatException,
    );
  });
  test('historical intent restoration refuses altered bytes foreign schemas bounds and noncanonical nested labels', () {
    final r = request(),
        data = jsonDecode(r.requestJson) as Map<String, dynamic>;
    for (final change in <Map<String, Object?>>[
      {'replacement': 'changed literal'},
      {'version': true},
      {'extra': true},
      {'run_id': '0' * 32},
      {'comparison_receipt_sha256': 'bad'},
      {'comparison_request': ' ${r.comparison.requestJson}'},
      {'sdk_identity': ' ${r.sdk.recordJson}'},
    ]) {
      expect(
        () => ImportedDartDiagnosticsRequest.restore(
          jsonEncode({...data, ...change}),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => ImportedDartDiagnosticsRequest.restore(
        r.requestJson.replaceFirst('{', '{"version":1,'),
      ),
      throwsFormatException,
    );
    expect(
      () => ImportedDartDiagnosticsRequest.restore(
        ' ' * (ImportedDartDiagnosticsRequest.byteLimit + 1),
      ),
      throwsFormatException,
    );
  });
  Map<String, Object?> observation(
    ImportedDartDiagnosticsRequest r,
    String status,
  ) => {
    'version': 1,
    'scope': 'imported-dart-diagnostics',
    'request_sha256': r.digest,
    'run_id': r.runId,
    'comparison_request_sha256': r.comparison.digest,
    'sdk_identity_sha256': r.sdk.digest,
    'selected_path': r.selectedPath,
    'source_sha256': sha256.convert(utf8.encode(r.replacement)).toString(),
    'status': status,
    'reason': status == 'stopped'
        ? 'stopped'
        : status == 'unavailable'
        ? 'input_changed'
        : null,
    'protocol_version': ['clean', 'issues', 'incomplete'].contains(status)
        ? '1.40.1'
        : null,
    'diagnostics': ['issues', 'incomplete'].contains(status)
        ? [
            {
              'severity': 'ERROR',
              'type': 'COMPILE_TIME_ERROR',
              'code': status == 'incomplete'
                  ? 'uri_does_not_exist'
                  : 'invalid_assignment',
              'message': 'Owned fixture diagnostic',
              'offset': 0,
              'length': 1,
              'line': 1,
              'column': 1,
            },
          ]
        : [],
    'source_verified': false,
    'project_verified': false,
    'mutation_authorized': false,
    'execution_authorized': false,
    'recorded_at': DateTime.utc(2026).toIso8601String(),
  };
  test('isolated result states remain bounded and never verify a project', () {
    final r = request();
    for (final status in [
      'clean',
      'issues',
      'incomplete',
      'unavailable',
      'stopped',
    ]) {
      final v = ImportedDartDiagnosticsObservation.fromJson(
        jsonEncode(observation(r, status)),
        request: r,
      );
      expect(v.status.name, status);
      expect(v.verifiesProject, false);
      expect(v.authorizesProjectExecution, false);
      expect(v.authorizesMutation, false);
      expect(v.recordedAt, DateTime.utc(2026));
    }
  });
  test(
    'foreign identity or authority and unknown protocol cannot become a result',
    () {
      final r = request(), d = observation(request(), 'clean');
      for (final change in <Map<String, Object?>>[
        {'request_sha256': 'f' * 64},
        {'run_id': 'f' * 32},
        {'comparison_request_sha256': 'f' * 64},
        {'sdk_identity_sha256': 'f' * 64},
        {'source_sha256': 'f' * 64},
        {'selected_path': 'test/other.dart'},
        {'project_verified': true},
        {'source_verified': true},
        {'mutation_authorized': true},
        {'execution_authorized': true},
        {'protocol_version': '1.41.0'},
        {'version': true},
        {'extra': true},
        {'recorded_at': '2026-01-01'},
      ]) {
        expect(
          () => ImportedDartDiagnosticsObservation.fromJson(
            jsonEncode({...d, ...change}),
            request: r,
          ),
          throwsFormatException,
        );
      }
    },
  );
  test('malformed diagnostic ranges severity schemas and incomplete classification refuse', () {
    final r = request(),
        d = observation(request(), 'issues'),
        item =
            (observation(request(), 'issues')['diagnostics'] as List).single
                as Map<String, Object?>;
    for (final change in <Map<String, Object?>>[
      {'offset': -1},
      {'length': r.replacement.length + 1},
      {'line': 0},
      {'column': 0},
      {'severity': 'READY'},
      {'code': 'wrong-code'},
      {'type': 'bad-type'},
      {'message': 'x' * 2049},
      {'message': '\u0000'},
      {'extra': true},
    ]) {
      expect(
        () => ImportedDartDiagnosticsObservation.fromJson(
          jsonEncode({
            ...d,
            'diagnostics': [
              {...item, ...change},
            ],
          }),
          request: r,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => ImportedDartDiagnosticsObservation.fromJson(
        jsonEncode({...d, 'status': 'clean'}),
        request: r,
      ),
      throwsFormatException,
    );
    expect(
      () => ImportedDartDiagnosticsObservation.fromJson(
        jsonEncode({...d, 'status': 'incomplete'}),
        request: r,
      ),
      throwsFormatException,
    );
    expect(
      () => ImportedDartDiagnosticsObservation.fromJson(
        jsonEncode({
          ...d,
          'status': 'unavailable',
          'reason': 'input_changed',
          'protocol_version': null,
        }),
        request: r,
      ),
      throwsFormatException,
    );
  });
  test('duplicate oversized and mutable diagnostic evidence is rejected or immutable', () {
    final r = request(), d = observation(request(), 'issues');
    final v = ImportedDartDiagnosticsObservation.fromJson(
      jsonEncode(d),
      request: r,
    );
    expect(() => v.diagnostics.clear(), throwsUnsupportedError);
    expect(
      () => ImportedDartDiagnosticsObservation.fromJson(
        jsonEncode(d).replaceFirst('{', '{"version":1,'),
        request: r,
      ),
      throwsFormatException,
    );
    expect(
      () => ImportedDartDiagnosticsObservation.fromJson(
        ' ' * (ImportedDartDiagnosticsObservation.responseLimit + 1),
        request: r,
      ),
      throwsFormatException,
    );
  });
}
