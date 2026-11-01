// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/cpu_environment_preparation_host.dart';
import 'package:asg/services/runtime_host_native.dart';
import 'package:flutter_test/flutter_test.dart';

const success =
    'cpu runtime dependencies checked; model loading and memory adequacy remain unverified.';

class PreparationHost extends NativeRuntimeHost {
  PreparationHost({
    required super.supportDirectory,
    required super.loadAsset,
    super.discoveryTimeout,
  });
  @override
  bool get supported => true;
}

void main() {
  test('consent and Python required before helper writes', () async {
    var writes = 0;
    final host = PreparationHost(
      supportDirectory: () async {
        writes++;
        throw StateError('PRIVATE');
      },
      loadAsset: (_) async => '',
    );
    expect(host, isA<CpuEnvironmentPreparationHost>());
    for (final input in [('', true), ('python', false), ('  ', true)]) {
      await expectLater(
        host.prepareCpuEnvironment(input.$1, experimentalCpu: input.$2),
        throwsFormatException,
      );
    }
    expect(writes, 0);
    expect(host.working, false);
    expect(RuntimeBackend.values.map((e) => e.argument), [
      'auto',
      'mlx',
      'torch',
    ]);
  });
  test(
    'shipped helper checks APIs without invoking loaders or installation',
    () async {
      final folder = await Directory.systemTemp.createTemp('asg CPU APIs ');
      addTearDown(() => folder.delete(recursive: true));
      final source = await File('tools/qwen_backends.py').readAsString();
      final host = PreparationHost(
        supportDirectory: () async => folder,
        loadAsset: (_) async => '''import sys, types

def forbidden(*args, **kwargs):
 raise RuntimeError('PRIVATE API invoked')
torch = types.ModuleType('torch')
torch.set_num_threads = forbidden
torch.device = forbidden
transformers = types.ModuleType('transformers')
transformers.AutoTokenizer = types.SimpleNamespace(from_pretrained=forbidden)
transformers.Qwen3_5ForConditionalGeneration = types.SimpleNamespace(from_pretrained=forbidden)
safetensors = types.ModuleType('safetensors')
safetensors_torch = types.ModuleType('safetensors.torch')
safetensors_torch.load_file = forbidden
sys.modules.update(torch=torch, transformers=transformers, safetensors=safetensors)
sys.modules['safetensors.torch'] = safetensors_torch
import subprocess
subprocess.run = forbidden
$source''',
      );
      await host.prepareCpuEnvironment(
        '/usr/bin/python3',
        experimentalCpu: true,
      );
      expect(host.ownsProcess, false);
      expect(host.loading, false);
      expect(host.working, false);
      expect(await Directory('${folder.path}/.runtime-deps').exists(), false);
    },
  );
  for (final scenario in [
    'success',
    'malformed',
    'ready',
    'overflow',
    'timeout',
    'exit',
    'stderr',
  ]) {
    test('actual $scenario capture stays private, reaps and retries', () async {
      final folder = await Directory.systemTemp.createTemp('asg CPU prepare ');
      addTearDown(() => folder.delete(recursive: true));
      final pidFile = File('${folder.path}/pid');
      var first = true;
      final host = PreparationHost(
        supportDirectory: () async => folder,
        discoveryTimeout: const Duration(seconds: 1),
        loadAsset: (_) async {
          final action = !first
              ? 'print(${jsonEncode(success)})'
              : switch (scenario) {
                  'malformed' => "print('PRIVATE /secret')",
                  'ready' => "print('cpu ready')",
                  'overflow' => "print('PRIVATE' * 20000, flush=True)",
                  'timeout' => 'time.sleep(60)',
                  'exit' => 'sys.exit(2)',
                  'stderr' => "while True: sys.stderr.write('PRIVATE' * 1000); sys.stderr.flush()",
                  _ => 'print(${jsonEncode(success)})',
                };
          return '''import sys, os, time, pathlib
pathlib.Path(${jsonEncode(pidFile.path)}).write_text(str(os.getpid()))
assert sys.argv[1:] == ['--prepare', 'cpu', '--experimental-cpu']
print('PRIVATE /secret', file=sys.stderr)
$action
''';
        },
      );
      final events = <String>[];
      final subscription = host.events.listen(events.add);
      addTearDown(subscription.cancel);
      final operation = host.prepareCpuEnvironment(
        '/usr/bin/python3',
        experimentalCpu: true,
      );
      if (scenario == 'success') {
        await operation;
      } else {
        await expectLater(
          operation,
          throwsA(
            predicate(
              (e) =>
                  e is StateError &&
                  !e.toString().contains('PRIVATE') &&
                  !e.toString().contains('/secret'),
            ),
          ),
        );
      }
      final pid = (await pidFile.readAsString()).trim();
      expect((await Process.run('/bin/kill', ['-0', pid])).exitCode, isNot(0));
      first = false;
      await host.prepareCpuEnvironment(
        '/usr/bin/python3',
        experimentalCpu: true,
      );
      expect(host.working, false);
      expect(host.ownsProcess, false);
      expect(events, isEmpty);
    });
  }
  test('private support, asset and executable failures allow retry', () async {
    final folder = await Directory.systemTemp.createTemp('asg CPU failures ');
    addTearDown(() => folder.delete(recursive: true));
    for (final failure in ['support', 'asset', 'executable']) {
      var fail = true;
      final host = PreparationHost(
        supportDirectory: () async {
          if (fail && failure == 'support') throw StateError('PRIVATE /secret');
          return folder;
        },
        loadAsset: (_) async {
          if (fail && failure == 'asset') throw StateError('PRIVATE /secret');
          return 'print(${jsonEncode(success)})';
        },
      );
      await expectLater(
        host.prepareCpuEnvironment(
          failure == 'executable'
              ? '${folder.path}/PRIVATE'
              : '/usr/bin/python3',
          experimentalCpu: true,
        ),
        throwsA(
          predicate(
            (e) =>
                e is StateError &&
                !e.toString().contains('PRIVATE') &&
                !e.toString().contains('/secret'),
          ),
        ),
      );
      fail = false;
      await host.prepareCpuEnvironment(
        '/usr/bin/python3',
        experimentalCpu: true,
      );
      expect(host.working, false);
    }
  });
  test('overlapping host work rejected before second helper write', () async {
    final folder = await Directory.systemTemp.createTemp('asg CPU busy ');
    addTearDown(() => folder.delete(recursive: true));
    final gate = Completer<void>();
    final entered = Completer<void>();
    var writes = 0;
    final host = PreparationHost(
      supportDirectory: () async => folder,
      loadAsset: (_) async {
        writes++;
        entered.complete();
        await gate.future;
        return 'print(${jsonEncode(success)})';
      },
    );
    final first = host.prepareCpuEnvironment(
      '/usr/bin/python3',
      experimentalCpu: true,
    );
    await entered.future;
    await expectLater(
      host.prepareCpuEnvironment('/usr/bin/python3', experimentalCpu: true),
      throwsStateError,
    );
    expect(writes, 1);
    gate.complete();
    await first;
    expect(host.working, false);
  });
}
