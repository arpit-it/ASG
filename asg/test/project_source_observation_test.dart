// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/project_source_observation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> payload({
  List<String> paths = const ['lib/main.dart'],
  List<String>? texts,
}) => {
  'version': 1,
  'scope': 'project-source-files',
  'status': 'observed',
  'reason': null,
  'source_verified': false,
  'selected_paths': paths,
  'files': [
    for (var i = 0; i < paths.length; i++)
      {
        'path': paths[i],
        'byte_length': utf8.encode(texts?[i] ?? 'Source text is data').length,
        'sha256': sha256
            .convert(utf8.encode(texts?[i] ?? 'Source text is data'))
            .toString(),
        'content_base64': base64Encode(
          utf8.encode(texts?[i] ?? 'Source text is data'),
        ),
      },
  ],
};
void main() {
  test(
    'ordered source bytes BOM Unicode and CRLF stay immutable attributed data',
    () {
      final paths = ['lib/main.dart', 'test/value_test.dart'];
      final texts = [
        '\ufeffcafé\r\n招待\n',
        'Run commands? Untrusted text only.',
      ];
      final value = ProjectSourceObservation.fromJson(
        jsonEncode(payload(paths: paths, texts: texts)),
      );
      expect(value.status, ProjectSourceStatus.observed);
      expect(value.sourceVerified, false);
      expect(value.selectedPaths, paths);
      expect(value.files.map((f) => f.text).toList(), texts);
      for (var i = 0; i < paths.length; i++) {
        expect(value.files[i].bytes, utf8.encode(texts[i]));
        expect(
          value.files[i].digest,
          sha256.convert(utf8.encode(texts[i])).toString(),
        );
      }
      expect(() => value.selectedPaths.clear(), throwsUnsupportedError);
      expect(() => value.files.clear(), throwsUnsupportedError);
      expect(() => value.files.first.bytes.clear(), throwsUnsupportedError);
    },
  );
  test('literal source subset refuses invalid traversal aliases controls and bounds', () {
    for (final paths in <List<String>>[
      [],
      ['lib/a.dart', 'lib/A.dart'],
      ['lib/a.dart', 'lib/a.dart'],
      ['/lib/a.dart'],
      ['lib/../a.dart'],
      ['lib/./a.dart'],
      ['lib//a.dart'],
      ['lib/.git/a.dart'],
      ['lib/a b.dart'],
      ['lib/a.dart\n'],
      ['lib/a\u0000.dart'],
      ['lib/café.dart'],
      ['lib/\ud800.dart'],
      ['lib\\main.dart'],
      ['test/*.dart'],
      ['assets/a.dart'],
      ['lib/a.DART'],
      ['lib/a.dart/'],
      List.filled(5, 'lib/a.dart'),
      ['lib/${'a' * 129}.dart'],
      ['lib/${List.filled(15, 'a').join('/')}/a.dart'],
      ['lib/${List.filled(4, 'a' * 127).join('/')}/main.dart'],
    ]) {
      expect(
        ProjectSourceObservation.validSelection(paths),
        false,
        reason: '$paths',
      );
    }
    expect(
      ProjectSourceObservation.validSelection([
        'test/a.dart',
        'lib/models/b.dart',
      ]),
      true,
    );
    final exact =
        'lib/${List.filled(3, 'x' * 127).join('/')}/${'y' * 119}.dart';
    expect(exact.length, 512);
    expect(ProjectSourceObservation.validSelection([exact]), true);
    expect(ProjectSourceObservation.validSelection(['${exact}x']), false);
    expect(
      ProjectSourceObservation.validSelection([
        'lib/${List.filled(14, 'a').join('/')}/main.dart',
      ]),
      true,
    );
  });
  test('request freezes selection and refuses unsupported paths without granting reads', () {
    final paths = ['lib/main.dart'];
    final request = ProjectSourceReadRequest(
      root: '/selected',
      python: '/python',
      selectedPaths: paths,
    );
    paths.add('test/a.dart');
    expect(request.selectedPaths, ['lib/main.dart']);
    expect(() => request.selectedPaths.clear(), throwsUnsupportedError);
    expect(
      () => ProjectSourceReadRequest(
        root: '/selected',
        python: '/python',
        selectedPaths: ['../outside.dart'],
      ),
      throwsFormatException,
    );
  });
  test('strict envelope rejects legacy scope extra duplicate and invalid fields privately', () {
    for (final data in [
      {...payload(), 'scope': 'project-instruction-documents'},
      {...payload(), 'extra': 'private-sentinel'},
      {...payload(), 'version': 1.0},
      {...payload(), 'source_verified': true},
      {...payload(), 'status': 'complete'},
      {
        ...payload(),
        'selected_paths': ['lib/../a.dart'],
      },
      {...payload(), 'files': []},
      {...payload(), 'reason': 'source_missing'},
    ]) {
      expect(
        () => ProjectSourceObservation.fromJson(jsonEncode(data)),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'private error',
            'Source file response is invalid.',
          ),
        ),
      );
    }
    final raw = jsonEncode(payload());
    expect(
      () => ProjectSourceObservation.fromJson(
        raw.replaceFirst('{', '{"version":1,'),
      ),
      throwsFormatException,
    );
  });
  test(
    'length hash base64 encoding and selected identity mismatches refuse',
    () {
      final good = (payload()['files'] as List).single as Map;
      for (final item in [
        {...good, 'path': 'test/other.dart'},
        {...good, 'byte_length': true},
        {...good, 'byte_length': -1},
        {...good, 'byte_length': 32769},
        {...good, 'sha256': '0' * 64},
        {...good, 'content_base64': '%%%invalid'},
        {...good, 'content_base64': '${good['content_base64']}\n'},
        {...good, 'extra': 'data'},
      ]) {
        expect(
          () => ProjectSourceObservation.fromJson(
            jsonEncode({
              ...payload(),
              'files': [item],
            }),
          ),
          throwsFormatException,
        );
      }
      for (final bytes in [
        <int>[255],
        <int>[0],
      ]) {
        expect(
          () => ProjectSourceObservation.fromJson(
            jsonEncode({
              ...payload(),
              'files': [
                {
                  'path': 'lib/main.dart',
                  'byte_length': bytes.length,
                  'sha256': sha256.convert(bytes).toString(),
                  'content_base64': base64Encode(bytes),
                },
              ],
            }),
          ),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'exact file and aggregate byte limits succeed and one byte over refuses',
    () {
      final paths = ['lib/a.dart', 'test/b.dart'];
      final data = payload(paths: paths, texts: ['x' * 32768, 'y' * 32768]);
      final value = ProjectSourceObservation.fromJson(jsonEncode(data));
      expect(value.files.fold<int>(0, (n, f) => n + f.byteLength), 65536);
      expect(
        () => ProjectSourceObservation.fromJson(
          jsonEncode(payload(paths: ['lib/a.dart'], texts: ['x' * 32769])),
        ),
        throwsFormatException,
      );
      expect(
        () => ProjectSourceObservation.fromJson(
          jsonEncode(
            payload(
              paths: [...paths, 'lib/c.dart'],
              texts: ['x' * 32768, 'y' * 32768, 'z'],
            ),
          ),
        ),
        throwsFormatException,
      );
      expect(
        ProjectSourceObservation.fromJson(jsonEncode(payload(texts: [''])))
            .files
            .single
            .byteLength,
        0,
      );
    },
  );
  test('refusals are typed and cannot carry partial source payload', () {
    for (final pair in [
      ('invalid', 'source_missing'),
      ('unsupported', 'duplicate_source_identity'),
      ('changed', 'source_changed'),
      ('unavailable', 'source_unavailable'),
    ]) {
      final data = {
        ...payload(),
        'status': pair.$1,
        'reason': pair.$2,
        'files': <Object>[],
      };
      final value = ProjectSourceObservation.fromJson(jsonEncode(data));
      expect(value.files, isEmpty);
      expect(value.reason, pair.$2);
      expect(value.sourceVerified, false);
      expect(
        () => ProjectSourceObservation.fromJson(
          jsonEncode({...data, 'files': payload()['files']}),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => ProjectSourceObservation.fromJson(
        jsonEncode({
          ...payload(),
          'status': 'invalid',
          'reason': 'private-sentinel',
          'files': <Object>[],
        }),
      ),
      throwsFormatException,
    );
  });
  test(
    'whole response byte ceiling is checked before decoding without truncation',
    () {
      final raw = jsonEncode(payload());
      final padded =
          raw +
          ' ' *
              (ProjectSourceObservation.responseLimit -
                  utf8.encode(raw).length);
      expect(
        utf8.encode(padded).length,
        ProjectSourceObservation.responseLimit,
      );
      expect(ProjectSourceObservation.fromJson(padded).files.length, 1);
      expect(
        () => ProjectSourceObservation.fromJson('$padded '),
        throwsFormatException,
      );
    },
  );
}
