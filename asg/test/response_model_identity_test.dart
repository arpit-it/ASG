// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/ask_controller.dart';
import 'package:asg/services/ask_store.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/local_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'ask_controller_test.dart' show AskRecords;

Map<String, Object?> completion({
  Object? model = 'selected',
  bool omit = false,
}) => {
  if (!omit) 'model': model,
  'choices': [
    {
      'message': {'content': 'Answer'},
      'delta': {'content': 'Answer'},
      'finish_reason': 'stop',
    },
  ],
};

String sse(Map<String, Object?> data) => 'data: ${jsonEncode(data)}\n\n';

void main() {
  test('Ask discards partial mismatched reply without completed provenance; retry recovers', () async {
    final records = AskRecords();
    var reject = false;
    final controller = AskController(
      AskStore(records),
      createProvider: (config) => LocalModelProvider(
        config,
        client: MockClient(
          (_) async => http.Response(
            '${sse(completion(model: config.model))}'
            '${reject ? sse(completion(model: 'other')) : ''}'
            'data: [DONE]\n\n',
            200,
            headers: {'content-type': 'text/event-stream'},
          ),
        ),
      ),
    )..load();
    addTearDown(controller.dispose);
    expect(await controller.send('first'), isTrue);
    final firstReply = controller.messages.last;
    reject = true;
    expect(await controller.send('second'), isTrue); // The question was saved.
    expect(controller.error, isNotNull);
    expect(controller.messages.where((m) => m.role == 'assistant'), [
      firstReply,
    ]);
    expect(controller.messages.last.role, 'user');
    final reopened = AskController(AskStore(records))..load();
    expect(reopened.messages.where((m) => m.role == 'assistant').length, 1);
    expect(reopened.messages.last.modelRequest, isNull);
    reopened.dispose();
    reject = false;
    expect(await controller.retryAnswer(), isTrue);
    expect(controller.messages.where((m) => m.role == 'assistant').length, 2);
  });
  for (final streaming in [false, true]) {
    for (final omit in [false, true]) {
      test(
        'matching or omitted model works: stream=$streaming omit=$omit',
        () async {
          final data = completion(omit: omit);
          final provider = LocalModelProvider(
            const LocalModelConfig(model: 'selected'),
            client: MockClient(
              (_) async => http.Response(
                streaming ? '${sse(data)}data: [DONE]\n\n' : jsonEncode(data),
                200,
                headers: {
                  'content-type': streaming
                      ? 'text/event-stream'
                      : 'application/json',
                },
              ),
            ),
          );
          addTearDown(provider.cancel);
          expect(await provider.generate('instruction').join(), 'Answer');
        },
      );
    }
    for (final identity in <Object?>[
      'private-wrong-model',
      '',
      null,
      12,
      ['selected'],
      {'id': 'selected'},
    ]) {
      test(
        'contradictory model fails privately: stream=$streaming value=$identity',
        () async {
          final data = completion(model: identity);
          final provider = LocalModelProvider(
            const LocalModelConfig(model: 'selected'),
            client: MockClient(
              (_) async => http.Response(
                streaming ? '${sse(data)}data: [DONE]\n\n' : jsonEncode(data),
                200,
                headers: {
                  'content-type': streaming
                      ? 'text/event-stream'
                      : 'application/json',
                },
              ),
            ),
          );
          addTearDown(provider.cancel);
          final chunks = <String>[];
          Object? failure;
          try {
            await for (final chunk in provider.generate(
              'private instruction',
            )) {
              chunks.add(chunk);
            }
          } catch (error) {
            failure = error;
          }
          expect(chunks, isEmpty);
          expect(failure, isA<StateError>());
          expect('$failure', contains('model ID'));
          expect('$failure', isNot(contains('private')));
        },
      );
    }
  }

  test(
    'actual HTTP late model change fails before contradictory text',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final serving = server.first.then((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['model'], 'selected');
        expect(body['max_tokens'], 256);
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(sse(completion()));
        request.response.write(sse(completion(model: 'private-other-model')));
        request.response.write('data: [DONE]\n\n');
        await request.response.close();
      });
      final provider = LocalModelProvider(
        LocalModelConfig(
          baseUrl: 'http://127.0.0.1:${server.port}/v1',
          model: 'selected',
        ),
      );
      addTearDown(provider.cancel);
      final chunks = <String>[];
      await expectLater(
        provider.generate('instruction').map((text) {
          chunks.add(text);
          return text;
        }).drain<void>(),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'guidance',
            contains('model ID'),
          ),
        ),
      );
      await serving;
      expect(chunks, ['Answer']);
    },
  );

  test('identity-only SSE payloads are checked before DONE', () async {
    final provider = LocalModelProvider(
      const LocalModelConfig(model: 'selected'),
      client: MockClient(
        (_) async => http.Response(
          '${sse(completion())}${sse({'model': 'other'})}data: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    addTearDown(provider.cancel);
    await expectLater(
      provider.generate('instruction').join(),
      throwsStateError,
    );
  });
}
