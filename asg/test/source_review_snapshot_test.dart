// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:asg/models/source_generation.dart';
import 'package:asg/services/source_review_snapshot.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  late Directory root;
  final sources = <String, String>{};
  Future<void> write(String name, List<int> bytes) async {
    final file = File(path.join(root.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    sources[name] = sha256.convert(bytes).toString();
  }

  GeneratedProject project() => GeneratedProject(
    directory: root.path,
    sdk: '',
    python: '',
    sources: sources,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('asg-source-review-');
    root = Directory(await root.resolveSymbolicLinks());
    sources.clear();
    await write('lib/main.dart', utf8.encode('void main() {}\n'));
  });
  tearDown(() async => root.delete(recursive: true));
  test('recorded bytes produce immutable review text without writes', () async {
    await write('test/main_test.dart', utf8.encode('// hello 🌍\n'));
    final snapshot = await readSourceReviewSnapshot(project(), [
      'lib/main.dart',
      'test/main_test.dart',
    ]);
    expect(snapshot['lib/main.dart'], 'void main() {}\n');
    expect(snapshot['test/main_test.dart'], '// hello 🌍\n');
    expect(() => snapshot.clear(), throwsUnsupportedError);
    expect(
      await File(path.join(root.path, 'lib/main.dart')).readAsString(),
      snapshot['lib/main.dart'],
    );
  });
  test('invalid selections and unrecorded files reject', () async {
    for (final selected in <List<String>>[
      [],
      ['lib/main.dart', 'lib/main.dart'],
      ['../main.dart'],
      ['/lib/main.dart'],
      ['lib/main.dart/extra'],
      ['pubspec.yaml'],
      ['lib/unknown.dart'],
      List.generate(9, (i) => 'lib/file$i.dart'),
    ]) {
      await expectLater(
        readSourceReviewSnapshot(project(), selected),
        throwsA(anything),
      );
    }
  });
  test('changed, missing and non-file recorded paths reject', () async {
    final saved = project();
    final file = File(path.join(root.path, 'lib/main.dart'));
    await file.writeAsString('changed');
    await expectLater(
      readSourceReviewSnapshot(saved, ['lib/main.dart']),
      throwsStateError,
    );
    await file.delete();
    await expectLater(
      readSourceReviewSnapshot(saved, ['lib/main.dart']),
      throwsStateError,
    );
    await Directory(file.path).create();
    await expectLater(
      readSourceReviewSnapshot(saved, ['lib/main.dart']),
      throwsStateError,
    );
  });
  test('linked root, directory and file reject', () async {
    final external = await Directory.systemTemp.createTemp(
      'asg-review-external-',
    );
    addTearDown(() => external.delete(recursive: true));
    final saved = project();
    final file = File(path.join(root.path, 'lib/main.dart'));
    await file.delete();
    final target = await File(path.join(external.path, 'main.dart'))
        .writeAsString('void main() {}\n');
    await Link(file.path).create(target.path);
    await expectLater(
      readSourceReviewSnapshot(saved, ['lib/main.dart']),
      throwsStateError,
    );
    await Link(file.path).delete();
    await Directory(path.join(root.path, 'lib')).delete();
    await Link(path.join(root.path, 'lib')).create(external.path);
    await expectLater(
      readSourceReviewSnapshot(saved, ['lib/main.dart']),
      throwsStateError,
    );
    final alias = Link(path.join(external.path, 'alias'));
    await alias.create(root.path);
    final linked = GeneratedProject(
      directory: alias.path,
      sdk: '',
      python: '',
      sources: sources,
    );
    await expectLater(
      readSourceReviewSnapshot(linked, ['lib/main.dart']),
      throwsStateError,
    );
  });
  test(
    'invalid UTF8, byte, text and encoded aggregate limits reject',
    () async {
      for (final bytes in [
        <int>[0xff],
        List.filled(128001, 32),
        List.filled(32001, 32),
      ]) {
        await write('lib/main.dart', bytes);
        await expectLater(
          readSourceReviewSnapshot(project(), ['lib/main.dart']),
          throwsFormatException,
        );
      }
      final selected = <String>[];
      for (var i = 0; i < 5; i++) {
        final name = 'lib/file$i.dart';
        selected.add(name);
        await write(name, List.filled(32000, 32));
      }
      await expectLater(
        readSourceReviewSnapshot(project(), selected),
        throwsFormatException,
      );
    },
  );
}
