// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

// Fixed dart:ui isolate proves Flutter engine execution, not a Flutter test suite.
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

Future<bool> denied(Future<void> Function() action) async {
  try {
    await action();
    return false;
  } catch (_) {
    return true;
  }
}

Future<void> main() async {
  final env = Platform.environment;
  final mode = env['PROBE_MODE']!;
  if (mode == 'timeout' || mode == 'cancel') {
    while (true) {}
  }
  if (mode == 'output') {
    while (true) {
      stdout.write('fixed-output-flood' * 1000);
    }
  }
  final results = <String, bool>{
    'engineApi': PlatformDispatcher.instance.views.isNotEmpty,
    'readDenied': await denied(() async {
      await File(env['SENTINEL']!).readAsString();
    }),
    'writeDenied': await denied(() async {
      await File(env['SENTINEL']!).writeAsString('changed');
    }),
    'spawnDenied': await denied(() async {
      await Process.run('/usr/bin/true', []);
    }),
    'canaryV4Denied': await denied(() async {
      final s = await Socket.connect(
        '127.0.0.1',
        int.parse(env['CANARY_PORT']!),
        timeout: const Duration(seconds: 1),
      );
      s.destroy();
    }),
    'canaryV6Denied': await denied(() async {
      final s = await Socket.connect(
        '::1',
        int.parse(env['CANARY_PORT']!),
        timeout: const Duration(seconds: 1),
      );
      s.destroy();
    }),
  };
  for (final host in ['127.0.0.1', '::1']) {
    final socket = await Socket.connect(
      host,
      int.parse(env['BROKER_PORT']!),
      timeout: const Duration(seconds: 1),
    );
    socket.writeln(
      jsonEncode({
        'schemaVersion': 1,
        'stage': 'engine',
        'family': host,
        'nonce': mode == 'malformed' ? 'wrong' : env['SESSION_NONCE'],
        'sourceHash': env['SOURCE_HASH'],
        'kernelHash': env['KERNEL_HASH'],
        'observations': results,
      }),
    );
    await socket.flush();
    await socket.close();
  }
  exit(results.values.every((value) => value) ? 0 : 2);
}
