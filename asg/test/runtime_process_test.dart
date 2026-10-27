// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/runtime_host_native.dart';

void main() {
  test(
    'process diagnostics omit raw stdout, stderr and malformed bytes',
    () async {
      final support = await Directory.systemTemp.createTemp(
        'asg-private-output-',
      );
      addTearDown(() => support.delete(recursive: true));
      final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
      final port = socket.port;
      await socket.close();
      final host = NativeRuntimeHost(
        port: port,
        supportDirectory: () async => support,
        loadAsset: (_) async => r'''import os, time
for _ in range(100):
    os.write(1, b"PRIVATE_PROMPT /private/checkpoint token=secret\n")
    os.write(2, b"PRIVATE_STDERR password=secret\xff\n")
time.sleep(60)
''',
      );
      final events = <String>[];
      final activity = Completer<void>();
      final stopped = Completer<void>();
      final subscription = host.events.listen((event) {
        events.add(event);
        if (event == 'Managed runtime stopped.' && !stopped.isCompleted) {
          stopped.complete();
        }
        if (event.contains('output received') && !activity.isCompleted) {
          activity.complete();
        }
      });
      addTearDown(subscription.cancel);
      addTearDown(() async {
        if (host.ownsProcess) await host.stop();
      });
      await host.start(
        const RuntimeSetup(python: '/usr/bin/python3', modelPath: '/unused'),
        'fixture',
      );
      await activity.future.timeout(const Duration(seconds: 10));
      await host.stop();
      await stopped.future.timeout(const Duration(seconds: 10));
      final diagnostics = events.join(' ');
      for (final private in [
        'PRIVATE_PROMPT',
        '/private/checkpoint',
        'token=',
        'PRIVATE_STDERR',
        'password=',
      ]) {
        expect(diagnostics, isNot(contains(private)));
      }
      expect(
        events.where((e) => e.contains('output received')).length,
        lessThanOrEqualTo(2),
      );
      expect(diagnostics, contains('Runtime process started.'));
      expect(diagnostics, contains('Runtime exited ('));
      expect(diagnostics, contains('Managed runtime stopped.'));
    },
    skip: !Platform.isMacOS,
  );

  test('native host starts and stops only its own process', () async {
    final support = await Directory.systemTemp.createTemp(
      'asg-runtime-process-',
    );
    addTearDown(() => support.delete(recursive: true));
    final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = socket.port;
    await socket.close();
    final host = NativeRuntimeHost(
      port: port,
      supportDirectory: () async => support,
      loadAsset: (_) async =>
          'import time\nprint("fixture ready", flush=True)\ntime.sleep(60)\n',
    );
    expect(host.ownsProcess, false);
    await expectLater(host.stop(), throwsStateError);
    final ready = host.events.firstWhere(
      (line) =>
          line ==
          'Runtime process output received. Raw output is hidden for privacy.',
    );
    await host.start(
      const RuntimeSetup(python: '/usr/bin/python3', modelPath: '/unused'),
      'fixture',
    );
    await ready.timeout(const Duration(seconds: 10));
    expect(host.ownsProcess, true);
    await host.stop();
    expect(host.ownsProcess, false);
  }, skip: !Platform.isMacOS);
}
