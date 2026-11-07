// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

// Developer fixture uses the reviewed installed SDK closure, not app dependencies.
// ignore: depend_on_referenced_packages
import 'package:hooks/hooks.dart';

Future<void> main(List<String> args) async {
  final env = Platform.environment;
  Future<void> probe(HookInput input) async {
    final observations = <String, bool>{};
    try {
      File(env['SENTINEL']!).readAsStringSync();
      observations['readDenied'] = false;
    } catch (_) {
      observations['readDenied'] = true;
    }
    try {
      File(env['SENTINEL']!).writeAsStringSync('changed');
      observations['writeDenied'] = false;
    } catch (_) {
      observations['writeDenied'] = true;
    }
    try {
      await Process.run('/usr/bin/true', []);
      observations['spawnDenied'] = false;
    } catch (_) {
      observations['spawnDenied'] = true;
    }
    for (final host in ['127.0.0.1', '::1']) {
      try {
        final socket = await Socket.connect(
          host,
          int.parse(env['BROKER_PORT']!),
          timeout: const Duration(milliseconds: 300),
        );
        socket.destroy();
        observations[host] = false;
      } catch (_) {
        observations[host] = true;
      }
    }
    File.fromUri(input.outputDirectoryShared.resolve('observations.json'))
        .writeAsStringSync(jsonEncode(observations));
    if (env['MODE'] == 'hook-timeout') {
      await Future<void>.delayed(const Duration(seconds: 15));
    }
    if (!observations.values.every((value) => value)) {
      exit(2);
    }
  }

  if (env['HOOK_STAGE'] == 'build') {
    await build(args, (input, output) async {
      await probe(input);
    });
  } else {
    await link(args, (input, output) async {
      await probe(input);
    });
  }
}
