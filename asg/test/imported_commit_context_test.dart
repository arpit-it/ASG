// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/imported_commit_context.dart';
import 'package:asg/models/imported_commit_source_observation.dart';
import 'package:asg/models/project_inspection.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

ProjectInspection commitInspection({
  String root = '/fixture/project',
  String sdk = '^3.0.0',
}) => ProjectInspection(
  root: root,
  packageName: 'fixture',
  dartSdk: sdk,
  runners: ['web'],
);
ImportedCommitReadRequest contextRequest({
  String commit = '',
  String python = '/trusted/python',
}) => ImportedCommitReadRequest(
  root: '/fixture/project',
  python: python,
  commit: commit.isEmpty ? 'a' * 40 : commit,
  selectedPaths: ['lib/main.dart', 'test/peer.dart'],
);
Map<String, dynamic> contextObservationData({
  String? text,
  String? peer,
  String? commit,
}) => {
  'version': 1,
  'scope': 'imported-commit-source',
  'status': 'observed',
  'reason': null,
  'root': '/fixture/project',
  'commit': commit ?? 'a' * 40,
  'selected_paths': ['lib/main.dart', 'test/peer.dart'],
  'tree': 'b' * 40,
  'manifest_sha256': 'c' * 64,
  'manifest_files': 3,
  'source_verified': false,
  'working_tree': 'unknown',
  'conflict': 'unknown',
  'files': [
    for (final entry in {
      'lib/main.dart': text ?? '\ufeff// café 🐈\r\n',
      'test/peer.dart': peer ?? '',
    }.entries)
      (() {
        final bytes = utf8.encode(entry.value);
        return {
          'path': entry.key,
          'mode': '100644',
          'git_blob': sha1.convert([
            ...utf8.encode('blob ${bytes.length}\u0000'),
            ...bytes,
          ]).toString(),
          'byte_length': bytes.length,
          'sha256': sha256.convert(bytes).toString(),
          'content_base64': base64Encode(bytes),
        };
      })(),
  ],
};
ImportedCommitContext commitContext({
  Map<String, dynamic>? data,
  String? commit,
  ProjectInspection? inspection,
  RequirementsBoard? requirements,
  String python = '/trusted/python',
}) => ImportedCommitContext.capture(
  inspection: inspection ?? commitInspection(),
  requirements: requirements ?? RequirementsBoard(),
  request: contextRequest(commit: commit ?? '', python: python),
  observation: ImportedCommitSourceObservation.fromJson(
    jsonEncode(data ?? contextObservationData(commit: commit)),
  ),
);
void main() {
  test('separate canonical capture restores exact BOM CRLF multibyte and empty bytes', () {
    final a = commitContext(),
        b = ImportedCommitContext.restore(commitContext().recordJson);
    expect(a.recordJson, b.recordJson);
    expect(a.digest, b.digest);
    expect(a.digest, sha256.convert(utf8.encode(a.recordJson)).toString());
    expect(a.files.first.source.text, '\ufeff// café 🐈\r\n');
    expect(a.files.first.source.bytes, utf8.encode('\ufeff// café 🐈\r\n'));
    expect(a.files.last.source.bytes, isEmpty);
    expect(a.capturedFiles.last.text, '');
    expect(a.sourceVerified, false);
    expect(a.includesSource, true);
    expect(a.workingTree, 'unknown');
    expect(a.conflict, 'unknown');
    expect(a.commit, 'a' * 40);
    expect(a.tree, 'b' * 40);
    expect(a.manifestDigest, 'c' * 64);
    expect(a.recordJson, contains('captured-imported-commit-context'));
    expect(a.recordJson, isNot(contains('/trusted/python')));
    expect(() => a.files.clear(), throwsUnsupportedError);
    expect(() => a.files.first.source.bytes[0] = 0, throwsUnsupportedError);
    expect(() => a.capturedFiles.clear(), throwsUnsupportedError);
  });
  test(
    'all commit metadata and selected content participate in stable identity',
    () {
      final a = commitContext();
      for (final change in <void Function(Map<String, dynamic>)>[
        (d) => d['tree'] = 'd' * 40,
        (d) => d['manifest_sha256'] = 'e' * 64,
        (d) => d['manifest_files'] = 4,
        (d) => (d['files'] as List)[0]['mode'] = '100755',
      ]) {
        final d = contextObservationData();
        change(d);
        expect(commitContext(data: d).digest, isNot(a.digest));
      }
      expect(commitContext(commit: 'd' * 40).digest, isNot(a.digest));
      expect(
        commitContext(data: contextObservationData(text: '// changed\n'))
            .digest,
        isNot(a.digest),
      );
      expect(
        commitContext(data: contextObservationData(peer: '// changed peer\n'))
            .digest,
        isNot(a.digest),
      );
      expect(
        commitContext(inspection: commitInspection(sdk: '^3.1.0')).digest,
        isNot(a.digest),
      );
      expect(
        commitContext(requirements: RequirementsBoard(revision: 1)).digest,
        isNot(a.digest),
      );
      expect(commitContext(python: '/another/python').digest, a.digest);
      expect(a.recordJson, isNot(contains('observed_at')));
      expect(a.recordJson, isNot(contains('comparison_sha256')));
    },
  );
  test('captured app metadata and requirements match separately from disk or commit toolchains', () {
    final a = commitContext();
    expect(
      a.matchesPlanningInputs(commitInspection(), RequirementsBoard()),
      true,
    );
    expect(
      a.matchesPlanningInputs(
        commitInspection(root: '/another'),
        RequirementsBoard(),
      ),
      false,
    );
    expect(
      a.matchesPlanningInputs(
        commitInspection(sdk: 'changed'),
        RequirementsBoard(),
      ),
      false,
    );
    expect(
      a.matchesPlanningInputs(
        commitInspection(),
        RequirementsBoard(revision: 1),
      ),
      false,
    );
    final runners = ['web'];
    final inspection = ProjectInspection(
      root: '/fixture/project',
      packageName: 'fixture',
      dartSdk: '^3.0.0',
      runners: runners,
    );
    final b = commitContext(inspection: inspection), raw = b.recordJson;
    runners.add('macos');
    expect(b.recordJson, raw);
    expect(b.matchesPlanningInputs(inspection, RequirementsBoard()), true);
  });
  test('wrong request root commit readset and refused observations cannot capture context', () {
    final observed = ImportedCommitSourceObservation.fromJson(
      jsonEncode(contextObservationData()),
    );
    for (final request in [
      contextRequest(commit: 'd' * 40),
      ImportedCommitReadRequest(
        root: '/different',
        python: '/python',
        commit: 'a' * 40,
        selectedPaths: ['lib/main.dart', 'test/peer.dart'],
      ),
      ImportedCommitReadRequest(
        root: '/fixture/project',
        python: '/python',
        commit: 'a' * 40,
        selectedPaths: ['lib/main.dart'],
      ),
    ]) {
      expect(
        () => ImportedCommitContext.capture(
          inspection: commitInspection(),
          requirements: RequirementsBoard(),
          request: request,
          observation: observed,
        ),
        throwsFormatException,
      );
    }
    expect(
      () => commitContext(inspection: commitInspection(root: '/wrong')),
      throwsFormatException,
    );
    final refused = contextObservationData()
      ..addAll({
        'status': 'refused',
        'reason': 'object_unavailable',
        'tree': null,
        'manifest_sha256': null,
        'manifest_files': null,
        'files': [],
      });
    expect(() => commitContext(data: refused), throwsFormatException);
  });
  test('restore rejects authority schema identity byte and attribution corruption privately', () {
    final a = commitContext();
    for (final change in <void Function(Map<String, dynamic>)>[
      (d) => d['extra'] = true,
      (d) => d['version'] = 1.0,
      (d) => d['scope'] = 'captured-imported-source-context',
      (d) => d['source_verified'] = true,
      (d) => d['working_tree'] = 'clean',
      (d) => d['conflict'] = 'none',
      (d) => d['commit'] = 'HEAD',
      (d) => d['tree'] = '0' * 40,
      (d) => d['manifest_sha256'] = 'x' * 64,
      (d) => d['manifest_files'] = 1,
      (d) => d['manifest_files'] = 2049,
      (d) => d['selected_paths'] = ['lib/main.dart'],
      (d) => (d['files'] as List)[0]['text'] = 'changed',
      (d) => (d['files'] as List)[0]['git_blob'] = 'd' * 40,
      (d) => (d['files'] as List)[0]['mode'] = '120000',
      (d) => (d['files'] as List)[0]['byte_length'] = 1,
      (d) => (d['files'] as List)[0]['sha256'] = '0' * 64,
      (d) => (d['files'] as List)[0]['path'] = '../outside.dart',
      (d) => (d['files'] as List)[0]['extra'] = true,
      (d) => (d['metadata'] as Map)['extra'] = true,
      (d) => (d['metadata'] as Map)['runners'] = [1],
      (d) => d['requirements'] = null,
    ]) {
      final d = jsonDecode(a.recordJson) as Map<String, dynamic>;
      change(d);
      expect(
        () => ImportedCommitContext.restore(jsonEncode(d)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Saved captured commit context is invalid.',
          ),
        ),
      );
    }
  });
  test(
    'noncanonical duplicate unknown and unpaired Unicode inputs never restore',
    () {
      final a = commitContext(), raw = commitContext().recordJson;
      for (final invalid in [
        ' $raw',
        '$raw\n',
        raw.replaceFirst('"version":1', '"version":1,"version":1'),
        jsonEncode(
          (jsonDecode(raw) as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, v))
              .entries
              .toList()
              .reversed
              .fold<Map<String, dynamic>>({}, (m, e) => m..[e.key] = e.value),
        ),
        'x' * (ImportedCommitContext.byteLimit + 1),
      ]) {
        expect(
          () => ImportedCommitContext.restore(invalid),
          throwsFormatException,
        );
      }
      final d = jsonDecode(a.recordJson) as Map<String, dynamic>;
      (d['metadata'] as Map)['package'] = '\ud800';
      expect(
        () => ImportedCommitContext.restore(jsonEncode(d)),
        throwsFormatException,
      );
      expect(
        () => commitContext(
          inspection: ProjectInspection(
            root: '/fixture/project',
            packageName: '\udfff',
            dartSdk: '^3.0.0',
            runners: ['web'],
          ),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'JSON text expansion is bounded without truncating valid selected bytes',
    () {
      final d = contextObservationData(text: '"' * 32768, peer: '"' * 32768);
      final o = ImportedCommitSourceObservation.fromJson(jsonEncode(d));
      expect(o.files.fold<int>(0, (n, f) => n + f.source.byteLength), 65536);
      expect(
        () => ImportedCommitContext.capture(
          inspection: commitInspection(),
          requirements: RequirementsBoard(),
          request: contextRequest(),
          observation: o,
        ),
        throwsFormatException,
      );
      expect(o.files.first.source.byteLength, 32768);
    },
  );
}
