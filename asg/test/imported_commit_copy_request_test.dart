// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/imported_commit_copy_request.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_commit_proposal_record_test.dart' show historicalRecord;

void main() {
  ImportedCommitCopyRequest request({
    String python = '/trusted/python',
    String destination = '/copies',
    String attempt = '1234567890abcdef1234567890abcdef',
    String plan = 'Reviewed captured source',
    String after = '\ufeffafter\r\n',
  }) => ImportedCommitCopyRequest.create(
    saved: historicalRecord(planText: plan, after: after),
    python: python,
    destination: destination,
    attemptId: attempt,
  );

  test('request binds full immutable proposal history and original selected bytes without sending source text', () {
    final saved = historicalRecord();
    final value = ImportedCommitCopyRequest.create(
      saved: saved,
      python: '/trusted/python',
      destination: '/copies',
      attemptId: 'a' * 32,
    );
    final data = jsonDecode(value.requestJson) as Map;
    expect(data['scope'], 'imported-commit-copy-request');
    expect(data['commit'], saved.context.commit);
    expect(data['tree'], saved.context.tree);
    expect(data['manifest_sha256'], saved.context.manifestDigest);
    expect(data['context_sha256'], saved.context.digest);
    expect(data['plan_sha256'], saved.proposal.planDigest);
    expect(data['proposal_sha256'], saved.proposal.digest);
    expect(data['history_sha256'], saved.digest);
    final file = (data['selected_files'] as List).single as Map;
    expect(file['path'], 'lib/main.dart');
    expect(file['git_blob'], saved.proposal.source.gitBlob);
    expect(file['mode'], saved.proposal.source.mode);
    expect(file['sha256'], saved.proposal.source.source.digest);
    expect(file['byte_length'], utf8.encode('\ufeffbefore\r\n').length);
    expect(file.containsKey('text'), false);
    expect(data.containsKey('replacement'), false);
    expect(data.containsKey('expectedDigest'), false);
    expect(data.containsKey('candidate_fingerprint'), false);
    expect(value.appliesReplacement, false);
    expect(value.sourceVerified, false);
    expect(
      value.digest,
      sha256.convert(utf8.encode(value.requestJson)).toString(),
    );
    expect(
      utf8.encode(value.requestJson).length,
      lessThanOrEqualTo(ImportedCommitCopyRequest.byteLimit),
    );
  });
  test(
    'fresh attempt destination runtime plan and proposal each change identity',
    () {
      final value = request();
      expect(value.matches(request()), true);
      for (final other in [
        request(attempt: 'f' * 32),
        request(destination: '/other'),
        request(python: '/other/python'),
        request(plan: 'Changed reviewed plan'),
        request(after: '// different replacement'),
      ]) {
        expect(value.matches(other), false);
        expect(value.digest, isNot(other.digest));
      }
    },
  );
  test(
    'unsafe or noncanonical destinations refuse privately without normalizing',
    () {
      for (final destination in [
        '',
        '/',
        '//copies',
        'relative',
        '/copies/',
        '/copies/../other',
        '/project',
        '/PROJECT/inside',
        '/copies/Stable.APP/child',
        '/copies/new\nline',
        '/copies/\ud800',
        '/${'x' * 4096}',
      ]) {
        expect(
          () => request(destination: destination),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'private error',
              'Invalid immutable baseline-copy request.',
            ),
          ),
        );
      }
    },
  );
  test('trusted interpreter must remain outside source and destination', () {
    for (final python in [
      '/project/bin/python',
      '/PROJECT/python',
      '/copies/python',
      '/COPIES/nested/python',
      'python',
      '/trusted/../python',
      '/Applications/Other.app/python',
      '/trusted/python\u0000',
    ]) {
      expect(() => request(python: python), throwsFormatException);
    }
  });
  test('compact historical restore preserves exact identity and immutable selected metadata', () {
    final value = request();
    final restored = ImportedCommitCopyRequest.restore(value.requestJson);
    expect(restored.matches(value), true);
    expect(restored.digest, value.digest);
    expect(restored.selectedFiles.single.path, 'lib/main.dart');
    expect(() => restored.selectedFiles.clear(), throwsUnsupportedError);
  });
  test('compact restore rejects duplicate unknown noncanonical and malformed selected metadata', () {
    final raw = request().requestJson;
    for (final value in [
      '{}',
      '$raw ',
      raw.replaceFirst('{', '{"version":1,'),
      raw.replaceFirst('{', '{"unknown":true,'),
      'x' * (ImportedCommitCopyRequest.byteLimit + 1),
    ]) {
      expect(
        () => ImportedCommitCopyRequest.restore(value),
        throwsFormatException,
      );
    }
    for (final change in <void Function(Map<String, dynamic>)>[
      (d) => d['selected_files'][0]['unknown'] = true,
      (d) => d['selected_files'][0]['path'] = '../escape.dart',
      (d) => d['selected_files'][0]['mode'] = '120000',
      (d) => d['selected_files'][0]['git_blob'] = '0' * 40,
      (d) => d['selected_files'][0]['byte_length'] = 1.0,
      (d) => d['selected_files'][0]['byte_length'] = 32769,
      (d) => d['selected_files'][0]['sha256'] = 'private',
      (d) => d['selected_files'] = [],
      (d) => d['manifest_files'] = 0,
      (d) => d['plan_sha256'] = 'private',
    ]) {
      final data = jsonDecode(raw) as Map<String, dynamic>;
      change(data);
      expect(
        () => ImportedCommitCopyRequest.restore(jsonEncode(data)),
        throwsFormatException,
      );
    }
  });
  test('attempt identifier is exact bounded lowercase and nonzero', () {
    for (final attempt in [
      '',
      '0' * 32,
      'a' * 31,
      'a' * 33,
      'A' * 32,
      '${'a' * 32}\n',
    ]) {
      expect(() => request(attempt: attempt), throwsFormatException);
    }
  });
}
