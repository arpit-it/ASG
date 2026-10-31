// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/runtime_connection.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test(
    'health messages omit server text and retain startup identity',
    () async {
      for (final status in ['ready', 'loading', 'error', 'private-sentinel']) {
        final connection = RuntimeConnection(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'status': status,
                'backend': 'private-sentinel',
                'phase': 'private-sentinel',
                'model': 'private-model-sentinel',
                'model_path': '/private/path-sentinel',
              }),
              200,
            ),
          ),
        );
        final health = await connection.check(const LocalModelConfig());
        expect(health.detail, isNot(contains('sentinel')));
        expect(health.ready, status == 'ready');
        if (status == 'ready') {
          expect(health.model, 'private-model-sentinel');
          expect(health.modelPath, '/private/path-sentinel');
          expect(health.detail, contains('state is unavailable'));
        }
        connection.close();
      }
    },
  );
  test(
    'only known phases describe active work and loading stays truthful',
    () async {
      for (final phase in [null, 'idle', 'thinking', 'writing']) {
        final connection = RuntimeConnection(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({'status': 'ready', 'phase': phase}),
              200,
            ),
          ),
        );
        final health = await connection.check(const LocalModelConfig());
        expect(health.ready, isTrue);
        expect(health.idle, phase == 'idle');
        expect(
          health.detail,
          contains(switch (phase) {
            'idle' => 'No model request active',
            'thinking' => 'request is processing',
            'writing' => 'response is streaming',
            _ => 'state is unavailable',
          }),
        );
        connection.close();
      }
      final connection = RuntimeConnection(
        client: MockClient(
          (_) async => http.Response('{"status":"loading"}', 200),
        ),
      );
      final health = await connection.check(const LocalModelConfig());
      expect(health.ready, isFalse);
      expect(health.idle, isFalse);
      expect(health.detail, contains('model loading'));
      expect(health.detail, isNot(contains('ready')));
      connection.close();
    },
  );
  test('invalid records fail privately without claiming ready', () async {
    for (final body in [
      'private-sentinel',
      '[]',
      'null',
      '{}',
      '{"status":"ready","model":42}',
      '{"status":"ready","model_path":[]}',
    ]) {
      final connection = RuntimeConnection(
        client: MockClient((_) async => http.Response(body, 200)),
      );
      final health = await connection.check(const LocalModelConfig());
      expect(health.ready, isFalse);
      expect(health.detail, contains('invalid'));
      expect(health.detail, isNot(contains('sentinel')));
      connection.close();
    }
  });
  test(
    'timeout offline and HTTP failure give distinct private guidance',
    () async {
      final clients = [
        MockClient((_) async => throw TimeoutException('private-sentinel')),
        MockClient((_) async => throw http.ClientException('private-sentinel')),
        MockClient((_) async => http.Response('private-sentinel', 503)),
      ];
      final expected = [
        'timed out',
        'not reachable',
        'did not respond successfully',
      ];
      for (var i = 0; i < clients.length; i++) {
        final connection = RuntimeConnection(client: clients[i]);
        final health = await connection.check(const LocalModelConfig());
        expect(health.ready, isFalse);
        expect(health.detail, contains(expected[i]));
        expect(health.detail, isNot(contains('sentinel')));
        connection.close();
      }
    },
  );
}
