// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_commit_edit_request.dart';
import 'package:asg/models/imported_commit_edit_observation.dart';

import 'imported_commit_proposal_record_test.dart' show historicalRecord;
import 'imported_commit_edit_request_test.dart' show editBasis;

ImportedCommitEditRequest sampleEditRequest() {
  final saved = historicalRecord(), b = editBasis(saved);
  return ImportedCommitEditRequest.create(
    copyHistory: b.history,
    proposal: saved,
    reviewed: b.read,
    observation: b.result,
    python: '/fresh/python',
    destination: '/output',
    attemptId: 'c' * 32,
  );
}

Map<String, Object?> editData(
  ImportedCommitEditRequest r, {
  bool prepared = true,
  bool knownRun = true,
}) => {
  'version': 1,
  'scope': 'imported-commit-edit',
  'request_sha256': r.digest,
  'attempt_id': r.attemptId,
  'root': r.root,
  'source_copy': r.sourceCopy,
  'destination': r.destination,
  'commit': r.commit,
  'expected_source_fingerprint': r.expectedSourceFingerprint,
  'selected_path': r.selectedPath,
  'after_sha256': r.afterHash,
  'status': prepared ? 'prepared' : 'refused',
  'reason': prepared ? null : 'unavailable',
  'run_name': knownRun ? 'asg-self-candidate-abcdef12' : null,
  'copy_path': prepared
      ? '${r.destination}/asg-self-candidate-abcdef12/source-${r.commit}'
      : null,
  'fingerprint': prepared ? 'e' * 64 : null,
  'files': prepared ? r.manifestFiles : null,
  'bytes': prepared ? 1024 : null,
  'source_verified': false,
  'execution_authorized': false,
  'recorded_at': DateTime.utc(2026).toIso8601String(),
};
ImportedCommitEditObservation editResult(
  ImportedCommitEditRequest r, {
  bool prepared = true,
}) => ImportedCommitEditObservation.fromJson(
  jsonEncode(editData(r, prepared: prepared)),
  request: r,
);
void main() {
  test('prepared and refused receipts bind exact intent and preserve authority boundaries', () {
    final r = sampleEditRequest();
    final good = editResult(r);
    expect(good.status, ImportedCommitEditStatus.prepared);
    expect(
      good.copyPath,
      '/output/asg-self-candidate-abcdef12/source-${r.commit}',
    );
    expect(good.sourceVerified, false);
    expect(good.authorizesExecution, false);
    final refused = editResult(r, prepared: false);
    expect(refused.copyPath, isNull);
    expect(refused.reportedRun(r), '/output/asg-self-candidate-abcdef12');
  });
  test('foreign identity impossible completion and unknown data refuse', () {
    final r = sampleEditRequest(), data = editData(sampleEditRequest());
    for (final change in [
      {'request_sha256': 'a' * 64},
      {'source_copy': '/foreign'},
      {'after_sha256': 'a' * 64},
      {'selected_path': 'lib/other.dart'},
      {'copy_path': '/foreign'},
      {'fingerprint': r.expectedSourceFingerprint},
      {'files': 2049},
      {'bytes': 24 * 1024 * 1024 + 1},
      {'execution_authorized': true},
      {'source_verified': true},
      {'recorded_at': '2026-01-01'},
      {'extra': true},
    ]) {
      expect(
        () => ImportedCommitEditObservation.fromJson(
          jsonEncode({...data, ...change}),
          request: r,
        ),
        throwsFormatException,
      );
    }
    for (final raw in [
      'private',
      'x' * 32769,
      jsonEncode(data).replaceFirst('{', '{"version":1,'),
    ]) {
      expect(
        () => ImportedCommitEditObservation.fromJson(raw, request: r),
        throwsFormatException,
      );
    }
  });
  test('strict historical intent restores without current approval and rejects malformed fields', () {
    final r = sampleEditRequest();
    expect(ImportedCommitEditRequest.restore(r.requestJson).matches(r), true);
    final data = jsonDecode(r.requestJson) as Map;
    for (final change in [
      {'replacement': 'changed'},
      {'path': 'asg/lib/main.dart'},
      {'before_mode': '120000'},
      {'before_byte_length': 32769},
      {'manifest_files': 0},
      {'source_copy': '/foreign'},
      {'attempt_id': '0' * 32},
      {'extra': true},
      {'version': 1.0},
    ]) {
      expect(
        () =>
            ImportedCommitEditRequest.restore(jsonEncode({...data, ...change})),
        throwsFormatException,
      );
    }
    for (final raw in [
      '$r',
      '${r.requestJson} ',
      r.requestJson.replaceFirst('{', '{"version":1,'),
      'x' * 65537,
    ]) {
      expect(
        () => ImportedCommitEditRequest.restore(raw),
        throwsFormatException,
      );
    }
  });
}
