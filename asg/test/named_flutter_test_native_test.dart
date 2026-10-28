// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
@TestOn('mac-os || linux')
library;

import 'dart:async';
import 'dart:io';

import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/generation_host_native.dart';
import 'package:flutter_test/flutter_test.dart';

const target = FlutterTestTarget(
  file: 'test/a_test.dart',
  name: 'literal .* [x];',
);
const helper = '''import json, sys
args=sys.argv[1:]
def arg(name): return args[args.index(name)+1]
assert '--confined' in args
assert arg('--operation') == 'test'
print(json.dumps({'exitCode':0,'timedOut':False,'cancelled':False,'outputLimitExceeded':False,
 'targetedTest':{'file':arg('--test-file'),'name':arg('--test-name'),'status':'passed','reason':'executedExactTest'}}))
''';
void main() {
  late Directory temp;
  late NativeGenerationHost host;
  late GeneratedProject project;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('asg-named-native-');
    for (final file in [
      'bin/cache/flutter_tools.snapshot',
      'bin/cache/dart-sdk/bin/dart',
      'packages/flutter_tools/.dart_tool/package_config.json',
    ]) {
      final f = File('${temp.path}/$file');
      await f.parent.create(recursive: true);
      await f.writeAsString('fixture');
    }
    project = GeneratedProject(
      directory: temp.path,
      sdk: temp.path,
      python: 'python3',
      sources: {},
      confined: true,
    );
    host = NativeGenerationHost(loadAsset: (_) async => helper);
  });
  tearDown(() async {
    await host.dispose();
    await temp.delete(recursive: true);
  });
  test(
    'real confined Flutter named outcomes through native host',
    () async {
      final sdk = Platform.environment['ASG_REAL_NAMED_TEST_SDK']!;
      final root = Directory('${temp.path}/real');
      await Directory('${root.path}/test').create(recursive: true);
      await File('${root.path}/pubspec.yaml').writeAsString(
        'name: named_native_fixture\nenvironment:\n  sdk: ">=3.9.0 <4.0.0"\n'
        'dependencies:\n  flutter:\n    sdk: flutter\n'
        'dev_dependencies:\n  flutter_test:\n    sdk: flutter\n',
      );
      await File('${root.path}/test/named_test.dart').writeAsString(
        "import 'package:flutter_test/flutter_test.dart';\n"
        "void main() { test('literal .*', () => expect(2+2,4)); "
        "test('literal .* suffix', () => fail('PRIVATE_FAILURE')); "
        "test('skipped', () {}, skip: true); }\n",
      );
      final resolved = await Process.run('$sdk/bin/flutter', [
        'pub',
        'get',
        '--offline',
      ], workingDirectory: root.path);
      expect(
        resolved.exitCode,
        0,
        reason: 'Trusted fixture dependency resolution',
      );
      final real = NativeGenerationHost(
        loadAsset: (name) => File(name).readAsString(),
      );
      final selected = GeneratedProject(
        directory: await root.resolveSymbolicLinks(),
        sdk: sdk,
        python: 'python3',
        sources: {},
        confined: true,
      );
      try {
        for (final name in [
          'literal .*',
          'literal .* suffix',
          'skipped',
          'missing',
        ]) {
          final result = await real.runNamedFlutterTest(
            selected,
            FlutterTestTarget(file: 'test/named_test.dart', name: name),
            beforeStart: () async {},
          );
          expect(result.passed, name == 'literal .*', reason: name);
          expect(
            result.toJson().toString(),
            isNot(contains('PRIVATE_FAILURE')),
          );
          expect(result.toJson().toString(), isNot(contains(root.path)));
        }
      } finally {
        await real.dispose();
      }
    },
    skip:
        !Platform.isMacOS ||
        !Platform.environment.containsKey('ASG_REAL_NAMED_TEST_SDK'),
  );
  test(
    'literal selectors reach helper and typed exact result is returned',
    () async {
      var authorized = 0;
      final result = await host.runNamedFlutterTest(
        project,
        target,
        beforeStart: () async {
          authorized++;
        },
      );
      expect(authorized, 1);
      expect(result.passed, isTrue);
      expect(result.target.name, target.name);
    },
  );
  test(
    'unconfined or unsafe selection refuses before asset preparation',
    () async {
      var loaded = false;
      final guarded = NativeGenerationHost(
        loadAsset: (_) async {
          loaded = true;
          return helper;
        },
      );
      final unsafe = GeneratedProject(
        directory: temp.path,
        sdk: temp.path,
        python: 'python3',
        sources: {},
      );
      await expectLater(
        guarded.runNamedFlutterTest(unsafe, target, beforeStart: () async {}),
        throwsStateError,
      );
      await expectLater(
        guarded.runNamedFlutterTest(
          project,
          const FlutterTestTarget(file: '../a_test.dart', name: 'a'),
          beforeStart: () async {},
        ),
        throwsFormatException,
      );
      expect(loaded, isFalse);
      await guarded.dispose();
    },
  );
  test(
    'authorization failure prevents launch and reservation can be retried',
    () async {
      await expectLater(
        host.runNamedFlutterTest(
          project,
          target,
          beforeStart: () async {
            throw StateError('stale');
          },
        ),
        throwsStateError,
      );
      expect(
        (await host.runNamedFlutterTest(
          project,
          target,
          beforeStart: () async {},
        )).passed,
        isTrue,
      );
    },
  );
  test('overlap and cancellation during preparation refuse command', () async {
    final entered = Completer<void>(), release = Completer<void>();
    final pending = host.runNamedFlutterTest(
      project,
      target,
      beforeStart: () async {
        entered.complete();
        await release.future;
      },
    );
    await entered.future;
    await expectLater(
      host.runNamedFlutterTest(project, target, beforeStart: () async {}),
      throwsStateError,
    );
    host.cancelVerification();
    await expectLater(host.verify(project, (_) async {}), throwsStateError);
    release.complete();
    await expectLater(pending, throwsStateError);
  });
  test('generic live helper retains strict required flags', () async {
    final generic = NativeGenerationHost(
      loadAsset: (_) async =>
          "print('{\"exitCode\":0,\"output\":\"fixture\",\"timedOut\":false}')",
    );
    await expectLater(
      generic.runFlutterOperation(project, 'test'),
      throwsA(isA<TypeError>()),
    );
    await generic.dispose();
  });
  test(
    'generic zero exit without target metadata cannot establish pass',
    () async {
      final generic = NativeGenerationHost(
        loadAsset: (_) async => "print('{\"exitCode\":0,\"timedOut\":false,\"cancelled\":false,\"outputLimitExceeded\":false}')",
      );
      await expectLater(
        generic.runNamedFlutterTest(project, target, beforeStart: () async {}),
        throwsFormatException,
      );
      await generic.dispose();
    },
  );
}
