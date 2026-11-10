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
  test(
    'health keeps decoding declared and implicit response encodings',
    () async {
      const body = '{"status":"ready","model":"modèle"}';
      final connection = RuntimeConnection(
        client: MockClient((request) async {
          final utf8Body = request.url.port == 8765;
          return http.Response.bytes(
            utf8Body ? utf8.encode(body) : latin1.encode(body),
            200,
            headers: {
              'content-type': utf8Body
                  ? 'application/json'
                  : 'application/json; charset=iso-8859-1',
            },
          );
        }),
      );
      addTearDown(connection.close);
      for (final port in [8765, 8766]) {
        final health = await connection.check(
          LocalModelConfig(baseUrl: 'http://127.0.0.1:$port/v1'),
        );
        expect(health.model, 'modèle');
        expect(health.ready, isTrue);
      }
    },
  );

  test('health timeout cancels only its unfinished body', () async {
    final cancelled = Completer<void>();
    final body = StreamController<List<int>>(onCancel: cancelled.complete);
    addTearDown(body.close);
    var stall = true;
    final connection = RuntimeConnection(
      client: MockClient.streaming((request, _) async {
        if (stall) return http.StreamedResponse(body.stream, 200);
        return http.StreamedResponse(
          Stream.value(utf8.encode('{"status":"ready","model":"retry"}')),
          200,
        );
      }),
    );
    addTearDown(connection.close);

    final health = await connection.check(const LocalModelConfig());
    expect(health.detail, contains('timed out'));
    await cancelled.future.timeout(const Duration(seconds: 1));

    stall = false;
    final retry = await connection.check(const LocalModelConfig());
    expect(retry.model, 'retry');
    expect(retry.ready, isTrue);
  });

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
