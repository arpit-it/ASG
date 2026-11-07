// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';
import 'dart:ui';

Future<void> main() async {
  final env = Platform.environment;
  if (PlatformDispatcher.instance.views.isEmpty) {
    exit(2);
  }
  final token = env['MODE'] == 'wrong-token' ? 'wrong' : env['SESSION_TOKEN']!;
  for (final host in ['127.0.0.1', '[::1]']) {
    final socket = await WebSocket.connect(
      'ws://$host:${env['SERVER_PORT']}/$token',
    );
    socket.add(
      jsonEncode({
        'schema': 1,
        'session': token,
        'source': env['SOURCE_HASH'],
        'kernel': env['KERNEL_HASH'],
        'engine': true,
      }),
    );
    if (env['MODE'] == 'engine-timeout' || env['MODE'] == 'stop') {
      await Future<void>.delayed(const Duration(seconds: 15));
    }
    if (env['MODE'] == 'extra-frame') {
      socket.add('{}');
    }
    await socket.close();
  }
  exit(0);
}
