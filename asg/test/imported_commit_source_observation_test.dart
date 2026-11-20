// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_commit_source_observation.dart';

Map<String, dynamic> commitObservationFixture() {
  final bytes = utf8.encode('\ufeff// café\r\n');
  return {
    'version': 1,
    'scope': 'imported-commit-source',
    'status': 'observed',
    'reason': null,
    'root': '/fixture/project',
    'commit': 'a' * 40,
    'selected_paths': ['lib/main.dart'],
    'tree': 'b' * 40,
    'manifest_sha256': 'c' * 64,
    'manifest_files': 2,
    'source_verified': false,
    'working_tree': 'unknown',
    'conflict': 'unknown',
    'files': [
      {
        'path': 'lib/main.dart',
        'mode': '100644',
        'byte_length': bytes.length,
        'git_blob': sha1.convert([
          ...utf8.encode('blob ${bytes.length}\u0000'),
          ...bytes,
        ]).toString(),
        'sha256': sha256.convert(bytes).toString(),
        'content_base64': base64Encode(bytes),
      },
    ],
  };
}

ImportedCommitReadRequest commitReadFixture({String? commit}) =>
    ImportedCommitReadRequest(
      root: '/fixture/project',
      python: '/trusted/python',
      commit: commit ?? 'a' * 40,
      selectedPaths: ['lib/main.dart'],
    );
void main() {
  test(
    'typed observation preserves exact bytes identities and unknown authority',
    () {
      final value = ImportedCommitSourceObservation.fromJson(
        jsonEncode(commitObservationFixture()),
      );
      expect(value.matchesRequest(commitReadFixture()), true);
      expect(value.matchesRequest(commitReadFixture(commit: 'd' * 40)), false);
      expect(value.files.single.source.text, '\ufeff// café\r\n');
      expect(value.files.single.source.bytes, utf8.encode('\ufeff// café\r\n'));
      expect(value.sourceVerified, false);
      expect(value.workingTree, 'unknown');
      expect(value.conflict, 'unknown');
      expect(() => value.files.clear(), throwsUnsupportedError);
      expect(
        () => value.files.single.source.bytes.clear(),
        throwsUnsupportedError,
      );
    },
  );
  test('request freezes selection and refuses revision expressions or unsafe paths', () {
    final paths = ['lib/main.dart'];
    final request = ImportedCommitReadRequest(
      root: '/fixture/project',
      python: '/trusted/python',
      commit: 'a' * 40,
      selectedPaths: paths,
    );
    paths.clear();
    expect(request.selectedPaths, ['lib/main.dart']);
    for (final commit in ['HEAD', '0' * 40, 'A' * 40, '${'a' * 40}\n']) {
      expect(() => commitReadFixture(commit: commit), throwsFormatException);
    }
    expect(
      () => ImportedCommitReadRequest(
        root: '/fixture/project',
        python: '/fixture/project/python',
        commit: 'a' * 40,
        selectedPaths: ['lib/main.dart'],
      ),
      throwsFormatException,
    );
  });
  test('malformed schema authority counts and identities refuse privately', () {
    for (final pair in [
      ('scope', 'project-source-files'),
      ('source_verified', true),
      ('working_tree', 'clean'),
      ('conflict', false),
      ('version', 1.0),
      ('commit', 'HEAD'),
      ('tree', '0' * 40),
      ('manifest_files', 0),
      ('manifest_files', 2049),
      ('manifest_sha256', 'invalid'),
      ('manifest_sha256', '${'c' * 63}\n'),
      ('root', '/fixture/../project'),
      ('reason', 'private source text'),
    ]) {
      final value = commitObservationFixture()..[pair.$1] = pair.$2;
      expect(
        () => ImportedCommitSourceObservation.fromJson(jsonEncode(value)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'private error',
            'Invalid immutable commit source observation.',
          ),
        ),
      );
    }
    final value = commitObservationFixture()..['unexpected'] = true;
    expect(
      () => ImportedCommitSourceObservation.fromJson(jsonEncode(value)),
      throwsFormatException,
    );
    expect(
      () =>
          ImportedCommitSourceObservation.fromJson('{"version":1,"version":1}'),
      throwsFormatException,
    );
  });
  test('blob mode byte hash path mismatch and partial refusals cannot publish files', () {
    for (final pair in [
      ('git_blob', 'd' * 40),
      ('mode', '120000'),
      ('path', 'lib/other.dart'),
      ('byte_length', 0),
    ]) {
      final value = commitObservationFixture();
      (value['files'] as List).single[pair.$1] = pair.$2;
      expect(
        () => ImportedCommitSourceObservation.fromJson(jsonEncode(value)),
        throwsFormatException,
      );
    }
    final value = commitObservationFixture()
      ..['status'] = 'refused'
      ..['reason'] = 'deadline';
    expect(
      () => ImportedCommitSourceObservation.fromJson(jsonEncode(value)),
      throwsFormatException,
    );
  });
  test(
    'oversized responses refuse before any supplied identity is admitted',
    () {
      expect(
        () => ImportedCommitSourceObservation.fromJson(' ' * (128 * 1024 + 1)),
        throwsFormatException,
      );
    },
  );
  test(
    'attributed and unattributed refusals have no invented snapshot identities',
    () {
      final value = commitObservationFixture()
        ..['status'] = 'refused'
        ..['reason'] = 'deadline'
        ..['tree'] = null
        ..['manifest_sha256'] = null
        ..['manifest_files'] = null
        ..['files'] = [];
      final parsed = ImportedCommitSourceObservation.fromJson(
        jsonEncode(value),
      );
      expect(parsed.status, ImportedCommitSourceStatus.refused);
      expect(parsed.matchesRequest(commitReadFixture()), true);
      expect(parsed.files, isEmpty);
      expect(parsed.tree, isNull);
      value['root'] = null;
      value['commit'] = null;
      value['selected_paths'] = [];
      expect(
        ImportedCommitSourceObservation.fromJson(jsonEncode(value))
            .matchesRequest(commitReadFixture()),
        false,
      );
    },
  );
}
