// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

// Authored fixture, not a package hook loader. No caller source is accepted.
import 'dart:convert';
import 'dart:io';

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
  final results = <String, bool>{
    'readDenied': await denied(() async {
      await File(env['SENTINEL']!).readAsString();
    }),
    'writeDenied': await denied(() async {
      await File(env['SENTINEL']!).writeAsString('changed');
    }),
    'spawnDenied': await denied(() async {
      await Process.run('/usr/bin/true', []);
    }),
    'networkDenied': await denied(() async {
      final socket = await Socket.connect(
        '127.0.0.1',
        int.parse(env['BROKER_PORT']!),
        timeout: const Duration(seconds: 1),
      );
      socket.destroy();
    }),
  };
  await File('${env['TMPDIR']!}/hook-owned-output')
      .writeAsString('fixed hook output');
  stdout.writeln(jsonEncode(results));
  exit(results.values.every((value) => value) ? 0 : 2);
}
