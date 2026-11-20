// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/local_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

String _reply(bool sse, String members) =>
    '{$members,"choices":[${sse ? '{"delta":{"content":"Ready"},"finish_reason":"stop"}' : '{"message":{"content":"Ready"},"finish_reason":"stop"}'}]}';

LocalModelProvider _provider(bool sse, String raw) => LocalModelProvider(
  const LocalModelConfig(model: 'selected'),
  client: MockClient(
    (_) async => http.Response(
      sse ? 'data: $raw\n\ndata: [DONE]\n\n' : raw,
      200,
      headers: {'content-type': sse ? 'text/event-stream' : 'application/json'},
    ),
  ),
);

void main() {
  for (final sse in [false, true]) {
    test('duplicate response metadata fails privately sse=$sse', () async {
      for (final members in [
        '"model":"private-foreign","model":"selected"',
        '"model":"selected","model":"selected"',
        r'"model":"private-foreign","\u006dodel":"selected"',
        '"model":"selected","metadata":{"id":1,"id":2}',
        '"model":"selected","metrics":{"output_tokens":1,"output_tokens":2}',
      ]) {
        final provider = _provider(sse, _reply(sse, members));
        try {
          await expectLater(
            provider.generate('private-prompt').join(),
            throwsA(
              isA<StateError>().having(
                (error) => error.toString(),
                'private diagnostic',
                isNot(contains('private-')),
              ),
            ),
          );
          expect(provider.completedResponseModel, isNull);
          expect(provider.completedMetrics, isNull);
        } finally {
          await provider.cancel();
        }
      }
    });
    test(
      'unique and absent optional model remain compatible sse=$sse',
      () async {
        for (final members in [
          r'"\u006dodel":"selected","metadata":{"a":1},"other":{"a":2}',
          '"metadata":{"model":"unrelated"}',
        ]) {
          final provider = _provider(sse, _reply(sse, members));
          try {
            expect(await provider.generate('Synthetic').join(), 'Ready');
            expect(
              provider.completedResponseModel,
              members.contains('unrelated') ? isNull : 'selected',
            );
          } finally {
            await provider.cancel();
          }
        }
      },
    );
    test('malformed response stays private sse=$sse', () async {
      for (final raw in ['"private-unterminated', '}', '{"model":']) {
        final provider = _provider(sse, raw);
        try {
          await expectLater(
            provider.generate('Synthetic').join(),
            throwsA(
              isA<StateError>().having(
                (e) => e.toString(),
                'private diagnostic',
                isNot(contains('private-')),
              ),
            ),
          );
          expect(provider.completedResponseModel, isNull);
          expect(provider.completedMetrics, isNull);
        } finally {
          await provider.cancel();
        }
      }
    });
  }
  test('ambiguous terminal frame cannot publish completed evidence', () async {
    final p = LocalModelProvider(
      const LocalModelConfig(model: 'selected'),
      client: MockClient(
        (_) async => http.Response(
          'data: {"model":"selected","choices":[{"delta":{"content":"Partial"}}]}\n\n'
          'data: {"model":"foreign","model":"selected","choices":[{"delta":{},"finish_reason":"stop"}]}\n\n'
          'data: [DONE]\n\n',
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    final text = <String>[];
    try {
      await expectLater(
        p.generate('Synthetic').map((value) {
          text.add(value);
          return value;
        }).drain<void>(),
        throwsStateError,
      );
      expect(text, ['Partial']);
      expect(p.completedResponseModel, isNull);
      expect(p.completedMetrics, isNull);
    } finally {
      await p.cancel();
    }
  });
}
