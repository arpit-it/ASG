// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/models/project_instruction_observation.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> response(List<int> bytes) => {
  'version': 1,
  'scope': 'project-instruction-documents',
  'status': 'observed',
  'reason': null,
  'selected_paths': ['AGENTS.md'],
  'source_verified': false,
  'documents': [
    {
      'path': 'AGENTS.md',
      'byte_length': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'content_base64': base64Encode(bytes),
    },
  ],
};
void main() {
  test('exact Unicode BOM bytes and attribution are immutable', () {
    const text = '\ufeffcafé\r\n招待\n';
    final bytes = utf8.encode(text);
    final value = ProjectInstructionObservation.fromJson(
      jsonEncode(response(bytes)),
    );
    expect(value.documents.single.text, text);
    expect(value.documents.single.bytes, bytes);
    expect(value.sourceVerified, false);
    expect(() => value.documents.single.bytes.add(1), throwsUnsupportedError);
    expect(() => value.documents.clear(), throwsUnsupportedError);
    expect(() => value.selectedPaths.clear(), throwsUnsupportedError);
  });
  test('partial forged unknown and duplicate responses fail privately', () {
    final original = response(utf8.encode('untrusted data'));
    for (final changes in [
      {'source_verified': true},
      {'version': 2},
      {'extra': 'private'},
      {
        'selected_paths': ['../private'],
      },
      {'reason': 'private'},
      {'status': 'invalid', 'reason': 'document_missing'},
      {
        'documents': [
          {
            'path': 'AGENTS.md',
            'byte_length': 0,
            'sha256': '0' * 64,
            'content_base64': '',
          },
        ],
      },
    ]) {
      expect(
        () => ProjectInstructionObservation.fromJson(
          jsonEncode({...original, ...changes}),
        ),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            'Instruction document response is invalid.',
          ),
        ),
      );
    }
    final raw = jsonEncode(original);
    for (final key in ['version', r'ver\u0073ion']) {
      expect(
        () => ProjectInstructionObservation.fromJson(
          '{"$key":1,${raw.substring(1)}',
        ),
        throwsFormatException,
      );
    }
  });
  test('request selection is frozen and unsafe selections refuse', () {
    final paths = ['AGENTS.md'];
    final request = ProjectInstructionReadRequest(
      root: '/fixture',
      python: '/python',
      selectedPaths: paths,
    );
    paths.add('README.md');
    expect(request.selectedPaths, ['AGENTS.md']);
    for (final selection in [
      <String>[],
      ['AGENTS.md', 'AGENTS.md'],
      ['README.md', 'AGENTS.md'],
      ['../AGENTS.md'],
    ]) {
      expect(
        () => ProjectInstructionReadRequest(
          root: '/fixture',
          python: '/python',
          selectedPaths: selection,
        ),
        throwsFormatException,
      );
    }
  });
  test('exact file and aggregate byte limits succeed without authority', () {
    final one = response(List.filled(32768, 65));
    final item = (one['documents'] as List).single as Map<String, Object?>;
    final two = {
      ...one,
      'selected_paths': ['AGENTS.md', 'README.md'],
      'documents': [
        item,
        {...item, 'path': 'README.md'},
      ],
    };
    final value = ProjectInstructionObservation.fromJson(jsonEncode(two));
    expect(value.documents.map((d) => d.byteLength).toList(), [32768, 32768]);
    expect(value.sourceVerified, false);
    expect(
      ProjectInstructionObservation.fromJson(jsonEncode(response([])))
          .documents
          .single
          .text,
      '',
    );
    expect(
      () => ProjectInstructionObservation.fromJson(
        jsonEncode(response(List.filled(32769, 65))),
      ),
      throwsFormatException,
    );
    expect(
      () => ProjectInstructionObservation.fromJson(' ' * 131073),
      throwsFormatException,
    );
  });
  test('bad encoding NUL altered hash or noncanonical base64 refuses', () {
    for (final bytes in [
      [255],
      [192, 128],
      [0],
    ]) {
      expect(
        () =>
            ProjectInstructionObservation.fromJson(jsonEncode(response(bytes))),
        throwsFormatException,
      );
    }
    final original = response([65]);
    final doc = (original['documents'] as List).single as Map<String, Object?>;
    for (final change in [
      {'sha256': '0' * 64},
      {'sha256': (doc['sha256'] as String).toUpperCase()},
      {'content_base64': 'QQ'},
      {'byte_length': true},
      {'byte_length': 0},
      {'extension': 'private'},
    ]) {
      expect(
        () => ProjectInstructionObservation.fromJson(
          jsonEncode({
            ...original,
            'documents': [
              {...doc, ...change},
            ],
          }),
        ),
        throwsFormatException,
      );
    }
  });
  test(
    'safe refusals have no partial documents or unknown private reasons',
    () {
      final value = {
        ...response([]),
        'status': 'changed',
        'reason': 'document_changed',
        'documents': [],
      };
      expect(
        ProjectInstructionObservation.fromJson(jsonEncode(value)).documents,
        isEmpty,
      );
      expect(
        () => ProjectInstructionObservation.fromJson(
          jsonEncode({...value, 'reason': 'private-sentinel'}),
        ),
        throwsFormatException,
      );
      expect(
        () => ProjectInstructionObservation.fromJson(
          jsonEncode({...value, 'status': 'observed'}),
        ),
        throwsFormatException,
      );
      expect(
        () => ProjectInstructionObservation.fromJson(
          jsonEncode({
            ...value,
            'selected_paths': ['unknown'],
          }),
        ),
        throwsFormatException,
      );
    },
  );
  test('selection and document correspondence is exact', () {
    final original = response([65]);
    for (final paths in [
      <String>[],
      ['AGENTS.md', 'AGENTS.md'],
      ['README.md', 'AGENTS.md'],
      ['README.md'],
    ]) {
      expect(
        () => ProjectInstructionObservation.fromJson(
          jsonEncode({...original, 'selected_paths': paths}),
        ),
        throwsFormatException,
      );
    }
  });
}
