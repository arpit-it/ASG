// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/imported_commit_copy_request.dart';
import 'package:asg/models/imported_commit_copy_observation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_commit_proposal_record_test.dart' show historicalRecord;

ImportedCommitCopyRequest copyRequest() => ImportedCommitCopyRequest.create(
  saved: historicalRecord(),
  python: '/trusted/python',
  destination: '/copies',
  attemptId: 'a' * 32,
);
Map<String, Object?> copyObservationData(
  ImportedCommitCopyRequest request, {
  bool prepared = true,
  bool knownRun = true,
}) => {
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
  'reason': prepared ? null : 'copy_unavailable',
  'run_name': knownRun ? 'asg-self-candidate-1234abcd' : null,
  'copy_path': prepared
      ? '${request.destination}/asg-self-candidate-1234abcd/source-${request.commit}'
      : null,
  'fingerprint': prepared ? 'f' * 64 : null,
  'files': prepared ? request.manifestFiles : null,
  'bytes': prepared ? 1024 : null,
  'source_verified': false,
  'working_tree': 'unknown',
  'conflict': 'unknown',
  'recorded_at': DateTime.utc(2026).toIso8601String(),
};
void main() {
  test('prepared result binds exact request and scoped original-copy path without new authority', () {
    final request = copyRequest();
    final value = ImportedCommitCopyObservation.fromJson(
      jsonEncode(copyObservationData(request)),
      request: request,
    );
    expect(value.status, ImportedCommitCopyStatus.prepared);
    expect(value.files, request.manifestFiles);
    expect(value.fingerprint, 'f' * 64);
    expect(value.reportedRun(request), '/copies/asg-self-candidate-1234abcd');
    expect(value.sourceVerified, false);
    expect(value.appliesReplacement, false);
    expect(
      ImportedCommitCopyObservation.fromJson(
        value.recordJson,
        request: request,
      ).recordJson,
      value.recordJson,
    );
  });
  test('refusal retains a reported run only as recovery evidence and never a ready path', () {
    final request = copyRequest();
    for (final known in [false, true]) {
      final value = ImportedCommitCopyObservation.fromJson(
        jsonEncode(
          copyObservationData(request, prepared: false, knownRun: known),
        ),
        request: request,
      );
      expect(value.status, ImportedCommitCopyStatus.refused);
      expect(value.copyPath, isNull);
      expect(value.fingerprint, isNull);
      expect(
        value.reportedRun(request),
        known ? '/copies/asg-self-candidate-1234abcd' : null,
      );
    }
  });
  test('foreign identity path mode and completion claims refuse privately', () {
    final request = copyRequest();
    for (final change in <void Function(Map<String, Object?>)>[
      (d) => d['request_sha256'] = 'b' * 64,
      (d) => d['attempt_id'] = 'b' * 32,
      (d) => d['root'] = '/other',
      (d) => d['destination'] = '/other',
      (d) => d['commit'] = 'b' * 40,
      (d) => d['tree'] = 'c' * 40,
      (d) => d['manifest_sha256'] = 'd' * 64,
      (d) => d['manifest_files'] = 1.0,
      (d) => d['source_verified'] = true,
      (d) => d['working_tree'] = 'clean',
      (d) => d['conflict'] = 'none',
      (d) => d['copy_path'] = '/owner/Stable.app',
      (d) => d['run_name'] = '../escape',
      (d) => d['run_name'] = null,
      (d) => d['fingerprint'] = 'private',
      (d) => d['files'] = 2,
      (d) => d['bytes'] = -1,
      (d) => d['bytes'] = 24 * 1024 * 1024 + 1,
      (d) => d['recorded_at'] = '2026-01-01T00:00:00+00:00',
      (d) => d['version'] = 1.0,
      (d) => d['unknown'] = true,
    ]) {
      final d = copyObservationData(request);
      change(d);
      expect(
        () => ImportedCommitCopyObservation.fromJson(
          jsonEncode(d),
          request: request,
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'private error',
            'Invalid immutable baseline-copy result.',
          ),
        ),
      );
    }
  });
  test('refusal cannot smuggle successful output or unknown reason', () {
    final request = copyRequest();
    for (final change in <void Function(Map<String, Object?>)>[
      (d) => d['copy_path'] = '/copies/ready',
      (d) => d['fingerprint'] = 'f' * 64,
      (d) => d['files'] = 1,
      (d) => d['bytes'] = 100,
      (d) => d['reason'] = null,
      (d) => d['reason'] = 'private error',
    ]) {
      final data = copyObservationData(request, prepared: false);
      change(data);
      expect(
        () => ImportedCommitCopyObservation.fromJson(
          jsonEncode(data),
          request: request,
        ),
        throwsFormatException,
      );
    }
  });
  test('duplicate malformed and oversized responses cannot be decoded', () {
    final request = copyRequest();
    final raw = jsonEncode(copyObservationData(request));
    for (final data in [
      'private',
      '{}',
      raw.replaceFirst('{', '{"version":1,'),
      'x' * (ImportedCommitCopyObservation.responseLimit + 1),
    ]) {
      expect(
        () => ImportedCommitCopyObservation.fromJson(data, request: request),
        throwsFormatException,
      );
    }
  });
}
