import 'dart:convert';
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/services/local_model.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/model_settings_store.dart';

void main() {
  test('local model settings persist', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    const config = LocalModelConfig(model: 'qwen-local');
    await ModelSettingsStore.fromPreferences(prefs).save(config);
    expect(
      ModelSettingsStore.fromPreferences(prefs).load().model,
      'qwen-local',
    );
  });
  test('reject remote endpoints before sending prompts', () {
    expect(
      () => const LocalModelConfig(baseUrl: 'https://example.com/v1').endpoint,
      throwsFormatException,
    );
    expect(
      () =>
          const LocalModelConfig(baseUrl: 'http://127.0.0.1:8080/v1/').endpoint
              .toString(),
      returnsNormally,
    );
  });
  test('uses selected model and decodes real API response shape', () async {
    final client = MockClient((request) async {
      expect(request.url.path, '/v1/chat/completions');
      final body = jsonDecode(request.body) as Map;
      expect(body['model'], 'qwen-test');
      return http.Response(
        jsonEncode({
          'choices': [
            {
              'message': {'content': 'Ready'},
            },
          ],
        }),
        200,
      );
    });
    final provider = LocalModelProvider(
      const LocalModelConfig(model: 'qwen-test'),
      client: client,
    );
    expect(await provider.generate('Hello').join(), 'Ready');
    await provider.cancel();
    expect(provider.generate('Again').join(), throwsStateError);
  });
  test('server failures remain failures', () async {
    final provider = LocalModelProvider(
      const LocalModelConfig(),
      client: MockClient((_) async => http.Response('error', 500)),
    );
    await expectLater(provider.generate('Hello').join(), throwsStateError);
    await provider.cancel();
  });
  test(
    'untrusted response and transport failures omit private content',
    () async {
      const secret = 'PRIVATE_PROMPT_SECRET_169';
      final clients = <http.Client>[
        MockClient(
          (_) async => http.Response(
            'data: {"error":"$secret"}\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        ),
        MockClient(
          (_) async => http.Response(
            'data: $secret\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        ),
        MockClient((_) async => http.Response(secret, 200)),
        MockClient(
          (_) async => http.Response(jsonEncode({'choices': secret}), 200),
        ),
        MockClient((_) async => throw http.ClientException(secret)),
        MockClient((_) async => throw StateError(secret)),
        MockClient((_) async => throw TimeoutException(secret)),
      ];
      for (var i = 0; i < clients.length; i++) {
        final provider = LocalModelProvider(
          const LocalModelConfig(),
          client: clients[i],
        );
        Object? failure;
        try {
          await provider.generate(secret).join();
        } catch (error) {
          failure = error;
        } finally {
          await provider.cancel();
        }
        expect(failure, isNotNull, reason: 'case $i');
        expect('$failure', isNot(contains(secret)), reason: 'case $i');
        expect(
          '$failure',
          anyOf(contains('runtime'), contains('local server')),
        );
        if (i == clients.length - 1) expect(failure, isA<TimeoutException>());
      }
    },
  );
  test(
    'safe busy and truncated guidance survives the privacy boundary',
    () async {
      for (final (response, guidance) in [
        (http.Response('private server detail', 429), 'busy'),
        (
          http.Response(
            jsonEncode({
              'choices': [
                {'finish_reason': 'length'},
              ],
            }),
            200,
          ),
          'truncated',
        ),
      ]) {
        final provider = LocalModelProvider(
          const LocalModelConfig(),
          client: MockClient((_) async => response),
        );
        await expectLater(
          provider.generate('Hello').join(),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'guidance',
              contains(guidance),
            ),
          ),
        );
        await provider.cancel();
      }
    },
  );
}
