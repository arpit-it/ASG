// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/cpu_runtime_launch_host.dart';
import 'package:asg/services/runtime_host_native.dart';
import 'package:flutter_test/flutter_test.dart';

class LaunchHost extends NativeRuntimeHost {
  LaunchHost({
    required super.port,
    required super.supportDirectory,
    required super.loadAsset,
  });
  @override
  bool get supported => true;
}

Future<void> until(bool Function() condition) async {
  final end = DateTime.now().add(const Duration(seconds: 5));
  while (!condition()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('Process lifecycle');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

const setup = RuntimeSetup(
  python: '/usr/bin/python3',
  modelPath: 'checkpoint with spaces',
  backend: RuntimeBackend.mlx,
);
void main() {
  test(
    'consent and invalid limits rejected before helpers or port activity',
    () async {
      var writes = 0;
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(socket.close);
      final host = LaunchHost(
        port: socket.port,
        supportDirectory: () async {
          writes++;
          throw StateError('PRIVATE');
        },
        loadAsset: (_) async => '',
      );
      expect(host, isA<CpuRuntimeLaunchHost>());
      for (final v in [
        (false, 2, null, const Duration(seconds: 180)),
        (true, 0, null, const Duration(seconds: 180)),
        (true, 33, null, const Duration(seconds: 180)),
        (true, 2, 0, const Duration(seconds: 180)),
        (true, 2, 9007199254740992, const Duration(seconds: 180)),
        (true, 2, null, Duration.zero),
        (true, 2, null, const Duration(microseconds: 3600000001)),
      ]) {
        await expectLater(
          host.startCpuRuntime(
            setup,
            'model',
            experimentalCpu: v.$1,
            threads: v.$2,
            maxWeightBytes: v.$3,
            loadTimeout: v.$4,
          ),
          throwsFormatException,
        );
      }
      for (final bad in [
        const RuntimeSetup(python: ' '),
        const RuntimeSetup(modelPath: ' '),
      ]) {
        await expectLater(
          host.startCpuRuntime(bad, 'model', experimentalCpu: true),
          throwsFormatException,
        );
      }
      await expectLater(
        host.startCpuRuntime(setup, ' ', experimentalCpu: true),
        throwsFormatException,
      );
      expect(writes, 0);
      expect(host.working, false);
      expect(host.ownsProcess, false);
      expect(RuntimeBackend.values.map((e) => e.argument), [
        'auto',
        'mlx',
        'torch',
      ]);
      expect(setup.toJson()['backend'], 'mlx');
    },
  );
  for (final mode in ['stop', 'exit', 'stderr']) {
    test(
      'actual CPU $mode arguments, private output, cleanup and retry',
      () async {
        final folder = await Directory.systemTemp.createTemp('asg CPU launch ');
        addTearDown(() => folder.delete(recursive: true));
        final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
        final port = socket.port;
        await socket.close();
        final record = File('${folder.path}/record');
        final host = LaunchHost(
          port: port,
          supportDirectory: () async => folder,
          loadAsset: (name) async => name != 'qwen_server.py'
              ? '# unused'
              : '''import sys, os, json, pathlib, time
pathlib.Path(${jsonEncode(record.path)}).write_text(json.dumps([os.getpid(),sys.argv[1:]]))
print('PRIVATE /secret',file=sys.stderr,flush=True)
${mode == 'exit'
                    ? 'sys.exit(3)'
                    : mode == 'stderr'
                    ? "while True: sys.stderr.write('PRIVATE'*1000); sys.stderr.flush()"
                    : 'time.sleep(60)'}
''',
        );
        addTearDown(() async {
          if (host.ownsProcess) await host.stop();
        });
        final events = <String>[];
        final sub = host.events.listen(events.add);
        addTearDown(sub.cancel);
        Future<void> launch() => host.startCpuRuntime(
          setup,
          'model ID',
          experimentalCpu: true,
          threads: 3,
          maxWeightBytes: 8192,
          loadTimeout: const Duration(milliseconds: 1250),
        );
        for (var attempt = 0; attempt < 2; attempt++) {
          if (await record.exists()) await record.delete();
          await launch();
          expect(host.working, false);
          await until(
            () => record.existsSync() && record.readAsStringSync().isNotEmpty,
          );
          final value = jsonDecode(await record.readAsString()) as List;
          expect(value[1], [
            '--backend',
            'cpu',
            '--experimental-cpu',
            '--cpu-threads',
            '3',
            '--cpu-load-timeout-seconds',
            '1.25',
            '--cpu-max-weight-bytes',
            '8192',
            '--model',
            'checkpoint with spaces',
            '--port',
            '$port',
            '--model-id',
            'model ID',
            '--parent-pid',
            '$pid',
          ]);
          if (mode != 'exit') {
            expect(host.ownsProcess, true);
            expect(host.loading, true);
            final before = record.readAsStringSync();
            await expectLater(launch(), throwsStateError);
            expect(record.readAsStringSync(), before);
            host.markReady();
            expect(host.loading, false);
            await host.stop();
          } else {
            await until(() => !host.ownsProcess);
          }
          expect(host.ownsProcess, false);
          expect(host.loading, false);
          expect(
            (await Process.run('/bin/kill', ['-0', '${value[0]}'])).exitCode,
            isNot(0),
          );
        }
        expect(events.join(), isNot(contains('PRIVATE')));
        expect(events.join(), isNot(contains('/secret')));
      },
    );
  }
  test('private port, helper and executable failures allow retry', () async {
    final folder = await Directory.systemTemp.createTemp('asg CPU failure ');
    addTearDown(() => folder.delete(recursive: true));
    for (final failure in ['port', 'support', 'asset', 'executable']) {
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      if (failure != 'port') await socket.close();
      var fail = true;
      final host = LaunchHost(
        port: port,
        supportDirectory: () async {
          if (fail && failure == 'support') throw StateError('PRIVATE /secret');
          return folder;
        },
        loadAsset: (_) async {
          if (fail && failure == 'asset') throw StateError('PRIVATE /secret');
          return 'import time; time.sleep(60)';
        },
      );
      addTearDown(() async {
        if (host.ownsProcess) await host.stop();
      });
      await expectLater(
        host.startCpuRuntime(
          failure == 'executable'
              ? const RuntimeSetup(
                  python: '/PRIVATE/secret',
                  modelPath: 'model',
                )
              : setup,
          'model',
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
      expect(host.working, false);
      expect(host.loading, false);
      expect(host.ownsProcess, false);
      if (failure == 'port') await socket.close();
      fail = false;
      await host.startCpuRuntime(setup, 'model', experimentalCpu: true);
      await host.stop();
    }
  });
  test(
    'default CPU limits are explicit and optional disk ceiling is absent',
    () async {
      final folder = await Directory.systemTemp.createTemp('asg CPU defaults ');
      addTearDown(() => folder.delete(recursive: true));
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final record = File('${folder.path}/defaults');
      final host = LaunchHost(
        port: port,
        supportDirectory: () async => folder,
        loadAsset: (name) async => name != 'qwen_server.py'
            ? '# unused'
            : '''import sys, json, pathlib
pathlib.Path(${jsonEncode(record.path)}).write_text(json.dumps(sys.argv[1:]))
''',
      );
      addTearDown(() async {
        if (host.ownsProcess) await host.stop();
      });
      await host.startCpuRuntime(setup, 'model', experimentalCpu: true);
      await until(
        () => record.existsSync() && record.readAsStringSync().isNotEmpty,
      );
      final args = jsonDecode(await record.readAsString()) as List;
      expect(args.take(7), [
        '--backend',
        'cpu',
        '--experimental-cpu',
        '--cpu-threads',
        '2',
        '--cpu-load-timeout-seconds',
        '180.0',
      ]);
      expect(args, isNot(contains('--cpu-max-weight-bytes')));
      await until(() => !host.ownsProcess);
    },
  );
  test('overlap rejected before helpers and legacy launch unchanged', () async {
    final folder = await Directory.systemTemp.createTemp('asg CPU overlap ');
    addTearDown(() => folder.delete(recursive: true));
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final gate = Completer<void>(), entered = Completer<void>();
    final record = File('${folder.path}/legacy');
    var writes = 0;
    final host = LaunchHost(
      port: port,
      supportDirectory: () async => folder,
      loadAsset: (name) async {
        writes++;
        if (writes == 1) {
          entered.complete();
          await gate.future;
        }
        return name != 'qwen_server.py'
            ? '# unused'
            : '''import sys, json, pathlib, time
pathlib.Path(${jsonEncode(record.path)}).write_text(json.dumps(sys.argv[1:]))
time.sleep(60)
''';
      },
    );
    addTearDown(() async {
      if (host.ownsProcess) await host.stop();
    });
    final first = host.start(setup, 'legacy');
    await entered.future;
    await expectLater(
      host.startCpuRuntime(setup, 'cpu', experimentalCpu: true),
      throwsStateError,
    );
    expect(writes, 1);
    gate.complete();
    await first;
    await until(record.existsSync);
    final args = jsonDecode(await record.readAsString()) as List;
    expect(args.take(2), ['--backend', 'mlx']);
    expect(args, isNot(contains('--experimental-cpu')));
    expect(args, isNot(contains('--cpu-load-timeout-seconds')));
    await host.stop();
  });
}
