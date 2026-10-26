import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/services/project_inspector.dart';
import 'package:asg/services/project_inspector_stub.dart' as stub;

void main() {
  late Directory root;
  const manifest = '''name: imported_app
environment:
  sdk: '>=3.0.0 <4.0.0'
dependencies:
  flutter:
    sdk: flutter
''';
  setUp(() async {
    root = await Directory.systemTemp.createTemp('asg_inspection_');
    root = Directory(await root.resolveSymbolicLinks());
    await Directory('${root.path}/lib').create();
    await File('${root.path}/lib/main.dart').writeAsString('void main() {}');
    await File('${root.path}/pubspec.yaml').writeAsString(manifest);
  });
  tearDown(() => root.delete(recursive: true));
  test('reads metadata and runners without changing project files', () async {
    await Directory('${root.path}/web').create();
    final before = await File('${root.path}/pubspec.yaml').readAsBytes();
    final result = await ProjectInspector().inspect(root.path);
    expect(result.packageName, 'imported_app');
    expect(result.dartSdk, '>=3.0.0 <4.0.0');
    expect(result.runners, ['web']);
    expect(await File('${root.path}/pubspec.yaml').readAsBytes(), before);
    expect(
      await File('${root.path}/lib/main.dart').readAsString(),
      'void main() {}',
    );
    expect((await root.list(recursive: true).toList()).length, 4);
    expect(() => result.runners.add('linux'), throwsUnsupportedError);
  });
  test('rejects invalid manifests without replacing them', () async {
    for (final text in [
      '',
      'name: bad-name',
      'name: x\nenvironment: {}',
      '$manifest\nname: duplicate',
      'name: [',
    ]) {
      final file = File('${root.path}/pubspec.yaml');
      await file.writeAsString(text);
      await expectLater(
        ProjectInspector().inspect(root.path),
        throwsA(isA<FormatException>()),
      );
      expect(await file.readAsString(), text);
    }
  });
  test(
    'rejects missing source, relative paths and oversized manifest',
    () async {
      await expectLater(
        ProjectInspector().inspect('relative'),
        throwsFormatException,
      );
      await File('${root.path}/pubspec.yaml').writeAsString(' ' * 65537);
      await expectLater(
        ProjectInspector().inspect(root.path),
        throwsFormatException,
      );
      await File('${root.path}/pubspec.yaml').writeAsString(manifest);
      await File('${root.path}/lib/main.dart').delete();
      await expectLater(
        ProjectInspector().inspect(root.path),
        throwsFormatException,
      );
    },
  );
  test('rejects linked root, manifest, source directory and runners', () async {
    final alias = Link('${root.path}_link');
    await alias.create(root.path);
    try {
      await expectLater(
        ProjectInspector().inspect(alias.path),
        throwsFormatException,
      );
    } finally {
      await alias.delete();
    }
    final original = File('${root.path}/original.yaml');
    await File('${root.path}/pubspec.yaml').rename(original.path);
    await Link('${root.path}/pubspec.yaml').create(original.path);
    await expectLater(
      ProjectInspector().inspect(root.path),
      throwsFormatException,
    );
    await Link('${root.path}/pubspec.yaml').delete();
    await original.rename('${root.path}/pubspec.yaml');
    await Link('${root.path}/web').create('${root.path}/lib');
    await expectLater(
      ProjectInspector().inspect(root.path),
      throwsFormatException,
    );
    await Link('${root.path}/web').delete();
    await Directory('${root.path}/lib').rename('${root.path}/source');
    await Link('${root.path}/lib').create('${root.path}/source');
    await expectLater(
      ProjectInspector().inspect(root.path),
      throwsFormatException,
    );
  });
  test('unsupported platform refuses inspection', () async {
    await expectLater(
      stub.ProjectInspector().inspect(root.path),
      throwsUnsupportedError,
    );
  });
}
