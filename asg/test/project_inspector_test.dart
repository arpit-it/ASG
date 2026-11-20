// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import 'package:asg/services/project_inspector.dart';
import 'package:asg/services/project_inspector_stub.dart' as stub;
import 'package:flutter_test/flutter_test.dart';

import 'project_metadata_import_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'actual packaged Mac inspector rejects linked manifest aliases',
    () async {
      const python =
          '/Library/Frameworks/Python.framework/Versions/3.12/bin/python3';
      final temp = await Directory.systemTemp.createTemp(
        'asg-contained-inspector-',
      );
      final outsideTemp = await Directory.systemTemp.createTemp(
        'asg-inspector-outside-',
      );
      final root = Directory(await temp.resolveSymbolicLinks());
      final outside = File('${outsideTemp.path}/outside.yaml');
      const manifest =
          'name: actual_packaged_fixture\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\ndependencies:\n  flutter:\n    sdk: flutter\n';
      final inspector = ProjectInspector();
      try {
        await Directory('${root.path}/lib').create();
        final main = File('${root.path}/lib/main.dart');
        await main.writeAsString('// inert; helper never reads this body\n');
        final selected = File('${root.path}/pubspec.yaml');
        await selected.writeAsString(manifest);
        await outside.writeAsString(
          manifest.replaceFirst('actual_packaged_fixture', 'outside_sentinel'),
        );
        final mainBefore = await main.readAsBytes(),
            outsideBefore = await outside.readAsBytes();
        final value = await inspector.inspect(root.path, python: python);
        expect(value.packageName, 'actual_packaged_fixture');
        expect(await selected.readAsString(), manifest);
        for (final hardlink in [true, false]) {
          if (await FileSystemEntity.type(selected.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            await selected.delete();
          }
          if (hardlink) {
            // Trusted OS fixture operation, never an imported-project command.
            final result = await Process.run('/bin/ln', [
              outside.path,
              selected.path,
            ], runInShell: false);
            expect(result.exitCode, 0);
          } else {
            await Link(selected.path).create(outside.path);
          }
          await expectLater(
            inspector.inspect(root.path, python: python),
            throwsA(
              isA<FormatException>().having(
                (e) => e.toString(),
                'private',
                isNot(contains('outside_sentinel')),
              ),
            ),
          );
          expect(await outside.readAsBytes(), outsideBefore);
          expect(await main.readAsBytes(), mainBefore);
        }
      } finally {
        await inspector.dispose();
        await temp.delete(recursive: true);
        await outsideTemp.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS
        ? 'Actual Mac packaged interpreter host; portable helper/transport tests remain active.'
        : false,
  );

  test('strict adapter uses explicit frozen root and interpreter', () async {
    final host = ImportHost();
    final inspector = ProjectInspector(host: host);
    final value = await inspector.inspect(
      '/selected',
      python: '/trusted/python',
    );
    expect(host.requests.single.root, '/selected');
    expect(host.requests.single.python, '/trusted/python');
    expect(value.root, '/selected');
    expect(value.packageName, 'controlled_app');
    expect(value.runners, ['web']);
    await inspector.cancel();
    await inspector.dispose();
    expect(host.cancels, 1);
    expect(host.disposals, 1);
  });
  test('transport errors cannot echo private data', () async {
    final host = ImportHost()
      ..read = () => Future.error(StateError('private-sentinel'));
    final inspector = ProjectInspector(host: host);
    await expectLater(
      inspector.inspect('/private-sentinel', python: '/trusted/python'),
      throwsA(
        isA<FormatException>().having(
          (e) => e.toString(),
          'private',
          isNot(contains('private-sentinel')),
        ),
      ),
    );
    await inspector.dispose();
  });
  test('unsupported backend never dispatches', () async {
    final host = ImportHost()..supported = false;
    final inspector = ProjectInspector(host: host);
    await expectLater(
      inspector.inspect('/selected', python: '/trusted/python'),
      throwsUnsupportedError,
    );
    expect(host.requests, isEmpty);
    await inspector.dispose();
  });
  test('explicit unsupported compatibility service fails closed', () async {
    final inspector = stub.ProjectInspector();
    expect(inspector.supported, isFalse);
    await expectLater(
      inspector.inspect('/selected', python: '/trusted/python'),
      throwsUnsupportedError,
    );
    await inspector.cancel();
    await inspector.dispose();
  });
}
