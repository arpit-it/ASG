// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:asg/models/generation_event.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/local_model.dart';
import 'package:asg/services/streamed_summary.dart';

http.Client sseClient(Stream<List<int>> body) =>
    MockClient.streaming((request, requestBody) async {
      expect(
        jsonDecode(await utf8.decoder.bind(requestBody).join())['stream'],
        true,
      );
      return http.StreamedResponse(
        body,
        200,
        headers: {'content-type': 'text/event-stream'},
      );
    });
String frame(String event, Object data) =>
    'event: $event\r\ndata: ${jsonEncode(data)}\r\n\r\n';
void main() {
  test('SSE decoding handles fragmented UTF8 and phases before completion', () async {
    final wire =
        '${frame('status', {'phase': 'thinking'})}${frame('status', {'phase': 'writing'})}${frame('message', {
          'choices': [
            {
              'delta': {'content': 'Hello 🌱'},
            },
          ],
        })}${frame('message', {
          'choices': [
            {'delta': {}, 'finish_reason': 'stop'},
          ],
        })}data: [DONE]\n\n';
    final bytes = utf8.encode(wire);
    final provider = LocalModelProvider(
      const LocalModelConfig(),
      client: sseClient(Stream.fromIterable(bytes.map((b) => [b]))),
    );
    final events = await provider.generateEvents('Hi').toList();
    expect(events.first.phase, GenerationPhase.thinking);
    expect(events.any((e) => e.phase == GenerationPhase.writing), true);
    expect(events.map((e) => e.text).join(), 'Hello 🌱');
    await provider.cancel();
  });
  test('text arrives before the stream has completed', () async {
    final chunks = StreamController<List<int>>();
    final provider = LocalModelProvider(
      const LocalModelConfig(),
      client: sseClient(chunks.stream),
    );
    final firstToken = Completer<String>();
    final reading = provider.generate('Hi').forEach((text) {
      if (!firstToken.isCompleted) firstToken.complete(text);
    });
    chunks.add(
      utf8.encode(
        frame('message', {
          'choices': [
            {
              'delta': {'content': 'Partial'},
            },
          ],
        }),
      ),
    );
    expect(await firstToken.future, 'Partial');
    chunks.add(utf8.encode('data: [DONE]\n\n'));
    await chunks.close();
    await reading;
    await provider.cancel();
  });
  test('truncated or abruptly closed output is rejected', () async {
    for (final ending in [
      '',
      '${frame('message', {
        'choices': [
          {'delta': {}, 'finish_reason': 'length'},
        ],
      })}data: [DONE]\n\n',
    ]) {
      final wire =
          frame('message', {
            'choices': [
              {
                'delta': {'content': 'partial'},
              },
            ],
          }) +
          ending;
      final provider = LocalModelProvider(
        const LocalModelConfig(),
        client: sseClient(Stream.value(utf8.encode(wire))),
      );
      await expectLater(provider.generate('Hi').join(), throwsStateError);
      await provider.cancel();
    }
  });
  test('SSE errors remain errors', () async {
    final provider = LocalModelProvider(
      const LocalModelConfig(),
      client: sseClient(
        Stream.value(
          utf8.encode(frame('error', {'error': 'Deadline exceeded'})),
        ),
      ),
    );
    await expectLater(provider.generate('Hi').join(), throwsStateError);
    await provider.cancel();
  });
  test(
    'inactive streams time out instead of leaving a permanent loader',
    () async {
      final chunks = StreamController<List<int>>();
      final provider = LocalModelProvider(
        const LocalModelConfig(),
        idleTimeout: const Duration(milliseconds: 20),
        client: sseClient(chunks.stream),
      );
      await expectLater(
        provider.generate('Hi').join(),
        throwsA(isA<TimeoutException>()),
      );
      await chunks.close();
      await provider.cancel();
    },
  );
  test('partial human summary handles JSON escapes without exposing edits', () {
    expect(streamedSummary('{"summary":"Add'), 'Add');
    expect(
      streamedSummary(r'{"summary":"Added \"hello\"\n\u263a", "edits":[]}'),
      'Added "hello"\n☺',
    );
    expect(streamedSummary(r'{"summary":"Hello\u26'), 'Hello');
    expect(streamedSummary('{"edits":[]}'), '');
  });
}
