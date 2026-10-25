import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/runtime_host_native.dart';

void main() {
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
      (line) => line.contains('fixture ready'),
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
