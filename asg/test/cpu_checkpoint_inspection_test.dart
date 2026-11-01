// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/cpu_checkpoint_inspection.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/runtime_host_native.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object?> report() => {
  'schema_version': 1,
  'backend': 'torch',
  'device': 'cpu',
  'experimental': true,
  'readiness': 'unverified',
  'checkpoint_structure': 'validated',
  'weight_bytes': 8,
  'weight_file_count': 2,
  'model_compatible': null,
  'memory_adequate': null,
  'inference_verified': false,
  'scope': 'PRIVATE /secret',
};

class InspectionHost extends NativeRuntimeHost {
  InspectionHost({
    required super.supportDirectory,
    required super.loadAsset,
    super.discoveryTimeout,
  });
  @override
  bool get supported => true;
}

void main() {
  test(
    'typed report keeps observations, never arbitrary scope or readiness',
    () {
      final value = CpuCheckpointInspection.fromJson(report());
      expect(value.weightBytes, 8);
      expect(value.weightFileCount, 2);
      expect(CpuCheckpointInspection.scope, isNot(contains('PRIVATE')));
      expect(RuntimeBackend.values.map((e) => e.argument), [
        'auto',
        'mlx',
        'torch',
      ]);
      for (final entry in <String, Object?>{
        'schema_version': 2,
        'backend': 'mlx',
        'device': 'mps',
        'experimental': false,
        'readiness': 'ready',
        'checkpoint_structure': 'unknown',
        'weight_bytes': 0,
        'weight_file_count': 9,
        'model_compatible': true,
        'memory_adequate': true,
        'inference_verified': true,
      }.entries) {
        expect(
          () => CpuCheckpointInspection.fromJson({
            ...report(),
            entry.key: entry.value,
          }),
          throwsFormatException,
          reason: entry.key,
        );
      }
      for (final bytes in [-1, 1.5, '8', 9007199254740992]) {
        expect(
          () => CpuCheckpointInspection.fromJson({
            ...report(),
            'weight_bytes': bytes,
          }),
          throwsFormatException,
        );
      }
      for (final key in report().keys.where((e) => e != 'scope')) {
        expect(
          () => CpuCheckpointInspection.fromJson({...report()}..remove(key)),
          throwsFormatException,
          reason: key,
        );
      }
    },
  );
  test('invalid consent and inputs cause no filesystem side effects', () async {
    var writes = 0;
    final host = InspectionHost(
      supportDirectory: () async {
        writes++;
        throw StateError('PRIVATE');
      },
      loadAsset: (_) async => '',
    );
    for (final input in [
      ('', 'model', true, null),
      ('python', '', true, null),
      ('python', 'model', false, null),
      ('python', 'model', true, 0),
    ]) {
      await expectLater(
        host.inspectCpuCheckpoint(
          input.$1,
          input.$2,
          experimentalCpu: input.$3,
          maxWeightBytes: input.$4,
        ),
        throwsFormatException,
      );
    }
    expect(writes, 0);
    expect(host.working, false);
  });
  test('shipped helper validates local structure without optional imports', () async {
    final folder = await Directory.systemTemp.createTemp('asg CPU structure ');
    addTearDown(() => folder.delete(recursive: true));
    await File('${folder.path}/config.json').writeAsString(
      jsonEncode({
        'architectures': ['Qwen3_5ForConditionalGeneration'],
      }),
    );
    await File('${folder.path}/model.safetensors')
        .writeAsBytes([1, 2, 3, 4, 5]);
    final host = InspectionHost(
      supportDirectory: () async => folder,
      loadAsset: (name) async {
        final source = await File('tools/$name').readAsString();
        return name != 'qwen_server.py'
            ? source
            : 'import sys\nclass RejectOptional:\n def find_spec(self, fullname, *args):\n  if fullname.split(".")[0] in ("torch", "transformers", "mlx", "safetensors"):\n   raise RuntimeError("optional import forbidden")\nsys.meta_path.insert(0, RejectOptional())\n$source';
      },
    );
    final value = await host.inspectCpuCheckpoint(
      '/usr/bin/python3',
      folder.path,
      experimentalCpu: true,
      maxWeightBytes: 5,
    );
    expect(value.weightBytes, 5);
    expect(value.weightFileCount, 1);
    expect(host.loading, false);
    expect(host.ownsProcess, false);
  });
  for (final scenario in [
    'success',
    'malformed',
    'ready',
    'overflow',
    'timeout',
    'exit',
    'ceiling',
  ]) {
    test('actual $scenario process is private, reaped and retryable', () async {
      final folder = await Directory.systemTemp.createTemp('asg CPU process ');
      addTearDown(() => folder.delete(recursive: true));
      final pidFile = File('${folder.path}/pid');
      var first = true;
      final host = InspectionHost(
        supportDirectory: () async => folder,
        discoveryTimeout: const Duration(seconds: 1),
        loadAsset: (name) async {
          if (name == 'qwen_backends.py') return '# unused';
          final action = !first
              ? 'print(${jsonEncode(jsonEncode(report()))})'
              : switch (scenario) {
                  'malformed' => "print('PRIVATE /secret')",
                  'ready' =>
                    'print(${jsonEncode(jsonEncode({...report(), 'readiness': 'ready'}))})',
                  'overflow' => "print('PRIVATE' * 20000, flush=True)",
                  'timeout' => 'time.sleep(60)',
                  'exit' => 'sys.exit(2)',
                  _ => 'print(${jsonEncode(jsonEncode(report()))})',
                };
          return '''import sys, os, time, pathlib
pathlib.Path(${jsonEncode(pidFile.path)}).write_text(str(os.getpid()))
assert sys.argv[1:] == ['--inspect-cpu-checkpoint', '--backend', 'cpu', '--experimental-cpu', '--model', 'model path with spaces', '--cpu-max-weight-bytes', '${first && scenario == 'ceiling' ? 7 : 8}']
print('PRIVATE /secret', file=sys.stderr)
$action
''';
        },
      );
      final events = <String>[];
      final subscription = host.events.listen(events.add);
      addTearDown(subscription.cancel);
      final operation = host.inspectCpuCheckpoint(
        '/usr/bin/python3',
        'model path with spaces',
        experimentalCpu: true,
        maxWeightBytes: scenario == 'ceiling' ? 7 : 8,
      );
      if (scenario == 'success') {
        expect((await operation).weightBytes, 8);
      } else {
        await expectLater(
          operation,
          throwsA(
            predicate(
              (e) =>
                  !e.toString().contains('PRIVATE') &&
                  !e.toString().contains('/secret'),
            ),
          ),
        );
      }
      final pid = (await pidFile.readAsString()).trim();
      expect((await Process.run('/bin/kill', ['-0', pid])).exitCode, isNot(0));
      first = false;
      expect(
        (await host.inspectCpuCheckpoint(
          '/usr/bin/python3',
          'model path with spaces',
          experimentalCpu: true,
          maxWeightBytes: 8,
        )).weightBytes,
        8,
      );
      expect(host.working, false);
      expect(host.ownsProcess, false);
      expect(events, isEmpty);
    });
  }
}
