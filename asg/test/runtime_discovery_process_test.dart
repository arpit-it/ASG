// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/services/runtime_host_native.dart';

import 'runtime_capabilities_test.dart' as fixture;

class PortableDiscoveryHost extends NativeRuntimeHost {
  PortableDiscoveryHost({
    required super.supportDirectory,
    required super.loadAsset,
    super.discoveryTimeout,
  });
  @override
  bool get supported => true;
}

void main() {
  test(
    'shipped helper discovers actual environment without model arguments',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'asg actual discovery ',
      );
      addTearDown(() => support.delete(recursive: true));
      final host = PortableDiscoveryHost(
        supportDirectory: () async => support,
        loadAsset: (name) => File('tools/$name').readAsString(),
      );
      final report = await host.discover('/usr/bin/python3');
      expect(report.backends.length, 2);
      expect(
        report.backends.every(
          (entry) =>
              entry.availability.contains('unverified') ||
              entry.availability.contains('Missing') ||
              entry.availability.contains('Unavailable'),
        ),
        true,
      );
      expect(host.ownsProcess, false);
    },
  );

  test(
    'scanner records format and refuses extra unsupported architectures',
    () async {
      final folder = await Directory.systemTemp.createTemp('asg model format ');
      addTearDown(() => folder.delete(recursive: true));
      for (final name in [
        'model.safetensors',
        'tokenizer.json',
        'tokenizer_config.json',
      ]) {
        await File('${folder.path}/$name').writeAsString('x' * 600);
      }
      final host = PortableDiscoveryHost(
        supportDirectory: () async => folder,
        loadAsset: (_) async => '',
      );
      for (final field in [
        'quantization',
        'quantization_config',
        'unquantized',
      ]) {
        await File('${folder.path}/config.json').writeAsString(
          jsonEncode({
            'architectures': ['Qwen3_5ForConditionalGeneration'],
            if (field != 'unquantized') field: {'bits': 4},
          }),
        );
        final model = (await host.scan(folder.path)).single;
        expect(model.supported, true);
        expect(model.quantized, field != 'unquantized');
      }
      await File('${folder.path}/config.json').writeAsString(
        jsonEncode({
          'architectures': ['Qwen3_5ForConditionalGeneration', 'Unknown'],
        }),
      );
      expect((await host.scan(folder.path)).single.supported, false);
    },
  );

  test(
    'actual discovery process uses no-model arguments and hides stderr',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'asg discovery with spaces ',
      );
      addTearDown(() => support.delete(recursive: true));
      final host = PortableDiscoveryHost(
        supportDirectory: () async => support,
        loadAsset: (name) async => name == 'qwen_backends.py'
            ? '# unused fixture'
            : '''import sys
assert sys.argv[1:] == ['--capabilities']
print('PRIVATE token=secret /private', file=sys.stderr)
print(${jsonEncode(jsonEncode(fixture.report()))})
''',
      );
      final events = <String>[];
      final subscription = host.events.listen(events.add);
      addTearDown(subscription.cancel);
      expect((await host.discover('/usr/bin/python3')).host, 'macOS / ARM64');
      expect(host.ownsProcess, false);
      expect(host.working, false);
      expect(events, isEmpty);
    },
  );
  for (final scenario in ['oversize', 'malformed', 'timeout', 'exit']) {
    test(
      'actual $scenario discovery reaps process and permits retry',
      () async {
        final support = await Directory.systemTemp.createTemp(
          'asg discovery failure ',
        );
        addTearDown(() => support.delete(recursive: true));
        final pidFile = File('${support.path}/pid');
        var fail = true;
        final host = PortableDiscoveryHost(
          supportDirectory: () async => support,
          discoveryTimeout: const Duration(seconds: 1),
          loadAsset: (name) async {
            if (name == 'qwen_backends.py') return '# unused fixture';
            final action = switch (scenario) {
              'oversize' => "print('PRIVATE' * 20000, flush=True)",
              'malformed' => "print('PRIVATE not JSON')",
              'timeout' => 'time.sleep(60)',
              _ => 'sys.exit(1)',
            };
            return '''import os, pathlib, sys, time
pathlib.Path(${jsonEncode(pidFile.path)}).write_text(str(os.getpid()))
${fail ? action : 'print(${jsonEncode(jsonEncode(fixture.report()))})'}
''';
          },
        );
        await expectLater(host.discover('/usr/bin/python3'), throwsA(anything));
        final childPid = int.parse(await pidFile.readAsString());
        expect(Process.killPid(childPid, ProcessSignal.sigkill), false);
        expect(host.working, false);
        expect(host.ownsProcess, false);
        fail = false;
        expect((await host.discover('/usr/bin/python3')).host, 'macOS / ARM64');
      },
    );
  }
}
