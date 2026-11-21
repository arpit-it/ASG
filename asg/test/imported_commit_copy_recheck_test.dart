// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/imported_commit_copy_recheck.dart';
import 'package:asg/models/imported_commit_copy_record.dart';
import 'package:asg/models/imported_commit_copy_request.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_commit_copy_observation_test.dart' show copyRequest;
import 'imported_commit_copy_record_test.dart' show copyResult;

ImportedCommitCopyRecord preparedCopyHistory() {
  final request = copyRequest();
  return ImportedCommitCopyRecord.empty(request.root)
      .begin(request, DateTime.utc(2026))
      .settle(request, copyResult(request), DateTime.utc(2026));
}

Map<String, Object?> recheckData(
  ImportedCommitCopyRecheckRequest request, {
  String status = 'matching',
}) => {
  'version': 1,
  'scope': 'imported-commit-copy-recheck',
  'request_sha256': request.digest,
  'recheck_id': request.recheckId,
  'copy_path': request.copyPath,
  'expected_fingerprint': request.expectedFingerprint,
  'status': status,
  'observed_fingerprint': status == 'refused'
      ? null
      : status == 'matching'
      ? request.expectedFingerprint
      : 'e' * 64,
  'files': status == 'refused' ? null : 1,
  'bytes': status == 'refused' ? null : 1024,
  'reason': status == 'refused' ? 'unavailable' : null,
  'source_verified': false,
  'mutation_authorized': false,
  'recorded_at': DateTime.utc(2026).toIso8601String(),
};
ImportedCommitCopyRecheckObservation recheckResult(
  ImportedCommitCopyRecheckRequest request, {
  String status = 'matching',
}) => ImportedCommitCopyRecheckObservation.fromJson(
  jsonEncode(recheckData(request, status: status)),
  request: request,
);
void main() {
  ImportedCommitCopyRecheckRequest request({String python = '/fresh/python'}) =>
      ImportedCommitCopyRecheckRequest.create(
        history: preparedCopyHistory(),
        python: python,
        recheckId: 'b' * 32,
      );
  test('read-only intent binds exact saved whole copy and current runtime without source text', () {
    final history = preparedCopyHistory(), value = request();
    final original = history.lastPrepared!;
    expect(value.root, history.root);
    expect(value.python, '/fresh/python');
    expect(value.historyDigest, history.digest);
    expect(value.copyRequestDigest, original.request.digest);
    expect(
      value.copyReceiptDigest,
      sha256.convert(utf8.encode(original.observation!.recordJson)).toString(),
    );
    expect(value.expectedFingerprint, original.observation!.fingerprint);
    expect(value.copyPath, original.observation!.copyPath);
    expect(value.copyAttemptId, original.request.attemptId);
    expect(value.recheckId, 'b' * 32);
    expect(value.authorizesMutation, false);
    expect(value.sourceVerified, false);
    expect(value.requestJson, isNot(contains('selected_files')));
    expect(value.requestJson, isNot(contains('after')));
    expect(
      ImportedCommitCopyRecheckRequest.restore(value.requestJson)
          .matches(value),
      true,
    );
  });
  test('empty pending refused and unconfirmed histories cannot become recheck authority', () {
    final original = copyRequest(), at = DateTime.utc(2026);
    final empty = ImportedCommitCopyRecord.empty(original.root),
        pending = ImportedCommitCopyRecord.empty(original.root)
            .begin(original, at);
    for (final history in [
      empty,
      pending,
      pending.settle(original, copyResult(original, prepared: false), at),
      pending.settle(original, copyResult(original), at, unconfirmed: true),
    ]) {
      expect(
        () => ImportedCommitCopyRecheckRequest.create(
          history: history,
          python: '/fresh/python',
          recheckId: 'b' * 32,
        ),
        throwsFormatException,
      );
    }
  });
  test('unresolved later attempt blocks old success; acknowledged recovery binds changed history', () {
    final history = preparedCopyHistory(), at = DateTime.utc(2026);
    final next = ImportedCommitCopyRequest.restore(
      history.lastPrepared!.request.requestJson.replaceFirst(
        'a' * 32,
        'c' * 32,
      ),
    );
    final pending = history.begin(next, at);
    expect(
      () => ImportedCommitCopyRecheckRequest.create(
        history: pending,
        python: '/fresh/python',
        recheckId: 'b' * 32,
      ),
      throwsFormatException,
    );
    final checked = ImportedCommitCopyRecheckRequest.create(
      history: pending.acknowledge(at),
      python: '/fresh/python',
      recheckId: 'b' * 32,
    );
    expect(checked.historyDigest, isNot(request().historyDigest));
    expect(checked.copyAttemptId, history.lastPrepared!.request.attemptId);
  });
  test('interpreter and physical target cannot be retargeted inside source or output', () {
    for (final python in [
      '/project/bin/python',
      '/copies/bin/python',
      '/PROJECT/python',
      'relative',
      '/Stable.app/python',
    ]) {
      expect(() => request(python: python), throwsFormatException);
    }
    final raw = jsonDecode(request().requestJson) as Map<String, dynamic>;
    for (final edit in [
      {'copy_path': '/foreign/source-${request().commit}'},
      {'run_name': '../other'},
      {'destination': '/project/output'},
      {'commit': '0' * 40},
      {'tree': 'bad'},
      {'recheck_id': '0' * 32},
      {'copy_receipt_sha256': 'bad'},
    ]) {
      expect(
        () => ImportedCommitCopyRecheckRequest.restore(
          jsonEncode({...raw, ...edit}),
        ),
        throwsFormatException,
      );
    }
  });
  test('malformed duplicate unknown noncanonical oversized and wrong-type input refuse', () {
    final raw = request().requestJson,
        data = jsonDecode(request().requestJson) as Map;
    for (final text in [
      'private',
      '{}',
      '$raw ',
      raw.replaceFirst('{', '{"version":1,'),
      jsonEncode({...data, 'extra': true}),
      jsonEncode({...data, 'version': 1.0}),
      jsonEncode({...data, 'python': true}),
      'x' * (ImportedCommitCopyRecheckRequest.byteLimit + 1),
    ]) {
      expect(
        () => ImportedCommitCopyRecheckRequest.restore(text),
        throwsFormatException,
      );
    }
  });
  test('restored labels are supplied intent only and must be rebuilt at app admission', () {
    final value = request(), raw = jsonDecode(value.requestJson) as Map;
    final changed = ImportedCommitCopyRecheckRequest.restore(
      jsonEncode({...raw, 'expected_fingerprint': 'e' * 64}),
    );
    expect(changed.matches(value), false);
    expect(changed.digest, isNot(value.digest));
    expect(changed.authorizesMutation, false);
  });
  test('dated matching changed and refused results bind exact intent without authority', () {
    final r = request();
    for (final status in ['matching', 'changed', 'refused']) {
      final value = recheckResult(r, status: status);
      expect(value.status.name, status);
      expect(value.requestDigest, r.digest);
      expect(value.authorizesMutation, false);
      expect(value.sourceVerified, false);
    }
  });
  test(
    'foreign changed malformed oversized and false completion results refuse',
    () {
      final r = request(), data = recheckData(request());
      for (final edit in [
        {'request_sha256': 'a' * 64},
        {'copy_path': '/foreign'},
        {'recheck_id': 'a' * 32},
        {'status': 'changed'},
        {'mutation_authorized': true},
        {'source_verified': true},
        {'files': 2049},
        {'bytes': 24 * 1024 * 1024 + 1},
        {'recorded_at': '2026-01-01'},
        {'reason': 'bad'},
        {'version': 1.0},
      ]) {
        expect(
          () => ImportedCommitCopyRecheckObservation.fromJson(
            jsonEncode({...data, ...edit}),
            request: r,
          ),
          throwsFormatException,
        );
      }
      for (final raw in [
        'private',
        'x' * (ImportedCommitCopyRecheckObservation.responseLimit + 1),
        jsonEncode(data).replaceFirst('{', '{"version":1,'),
      ]) {
        expect(
          () => ImportedCommitCopyRecheckObservation.fromJson(raw, request: r),
          throwsFormatException,
        );
      }
    },
  );
}
