// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/local_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const limit = LocalModelProvider.maxResponseBytes;
const answer = '{"choices":[{"message":{"content":"Ready"}}]}';
const delta = 'data: {"choices":[{"delta":{"content":"Ready"}}]}\n\n';
const done = 'data: [DONE]\n\n';

class TrackingClient extends http.BaseClient {
  TrackingClient(this.inner);
  final http.Client inner;
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      inner.send(request);
  @override
  void close() {
    closed = true;
    inner.close();
  }
}

TrackingClient clientFor(
  Stream<List<int>> body, {
  bool sse = false,
  int? length,
}) => TrackingClient(
  MockClient.streaming((_, request) async {
    await request.drain<void>();
    return http.StreamedResponse(
      body,
      200,
      contentLength: length,
      headers: sse ? {'content-type': 'text/event-stream'} : {},
    );
  }),
);
Matcher get oversized => throwsA(
  isA<StateError>().having(
    (error) => error.message,
    'private actionable guidance',
    allOf(
      contains('1 MiB'),
      contains('local server'),
      isNot(contains('PRIVATE')),
    ),
  ),
);
void main() {
  test('JSON and SSE accept exactly the byte ceiling with UTF8', () async {
    for (final sse in [false, true]) {
      final wire = (sse ? '$delta$done' : answer).replaceFirst(
        'Ready',
        'Ready 🌱',
      );
      final padding = List<int>.filled(limit - utf8.encode(wire).length, 32);
      final bytes = [...padding, ...utf8.encode(wire)];
      if (sse) {
        bytes[0] = 58;
        bytes[padding.length - 1] = 10;
      }
      final client = clientFor(
        Stream.fromIterable([
          bytes.sublist(0, limit - 3),
          bytes.sublist(limit - 3),
        ]),
        sse: sse,
        length: limit,
      );
      final provider = LocalModelProvider(
        const LocalModelConfig(),
        client: client,
      );
      expect(await provider.generate('Hi').join(), 'Ready 🌱');
      await provider.cancel();
    }
  });
  test(
    'valid oversized JSON and SSE fail instead of silently accepting',
    () async {
      for (final sse in [false, true]) {
        final wire = sse
            ? ':${' ' * limit}\n$delta$done'
            : '${' ' * limit}$answer';
        final client = clientFor(Stream.value(utf8.encode(wire)), sse: sse);
        final provider = LocalModelProvider(
          const LocalModelConfig(),
          client: client,
        );
        await expectLater(provider.generate('Hi').join(), oversized);
        expect(client.closed, true);
      }
    },
  );
  test('declared oversized body rejected before listening', () async {
    var listened = false;
    final body = Stream<List<int>>.multi((events) {
      listened = true;
      events.close();
    });
    final client = clientFor(body, length: limit + 1);
    final provider = LocalModelProvider(
      const LocalModelConfig(),
      client: client,
    );
    await expectLater(provider.generate('PRIVATE').join(), oversized);
    expect(listened, false);
    expect(client.closed, true);
  });
  test(
    'aggregate bytes bound JSON and newline-free SSE before decoding',
    () async {
      for (final sse in [false, true]) {
        var cancelled = false;
        final body = StreamController<List<int>>(
          onCancel: () {
            cancelled = true;
          },
        );
        final client = clientFor(body.stream, sse: sse);
        final provider = LocalModelProvider(
          const LocalModelConfig(),
          client: client,
        );
        final result = expectLater(
          provider.generate('PRIVATE').join(),
          oversized,
        );
        body.add(utf8.encode('PRIVATE'));
        body.add(List<int>.filled(limit - 7, 32));
        body.add([32]);
        await result;
        expect(client.closed, true);
        expect(cancelled, true);
        await body.close();
      }
    },
  );
  test('UTF8 bytes rather than characters determine overflow', () async {
    final client = clientFor(
      Stream.value(utf8.encode('🌱' * (limit ~/ 4 + 1))),
    );
    final provider = LocalModelProvider(
      const LocalModelConfig(),
      client: client,
    );
    await expectLater(provider.generate('Hi').join(), oversized);
    expect(client.closed, true);
  });
  test(
    'partial SSE then excess small frames fails instead of completing',
    () async {
      final body = StreamController<List<int>>();
      final client = clientFor(body.stream, sse: true);
      final provider = LocalModelProvider(
        const LocalModelConfig(),
        client: client,
      );
      final first = Completer<void>();
      final result = provider.generate('Hi').forEach((text) {
        expect(text, 'Ready');
        first.complete();
      });
      final failure = expectLater(result, oversized);
      body.add(utf8.encode(delta));
      await first.future;
      for (var i = 0; i < 1025; i++) {
        body.add(utf8.encode(':${' ' * 1022}\n'));
      }
      body.add(utf8.encode(done));
      await failure;
      expect(client.closed, true);
      await body.close();
    },
  );
  test(
    'actual chunked HTTP overflow refuses then fresh connection retries',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      var calls = 0;
      final served = server.listen((request) async {
        await request.drain<void>();
        if (calls++ == 0) {
          request.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          request.response.add(utf8.encode(delta));
          request.response.add(List<int>.filled(limit, 32));
        } else {
          request.response.headers.contentType = ContentType.json;
          request.response.write(answer);
        }
        try {
          await request.response.close();
        } catch (_) {
          /* peer refused */
        }
      });
      addTearDown(served.cancel);
      final config = LocalModelConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1/',
      );
      final first = LocalModelProvider(config);
      await expectLater(first.generate('Hi').join(), oversized);
      await first.cancel();
      final retry = LocalModelProvider(config);
      expect(await retry.generate('Hi').join(), 'Ready');
      await retry.cancel();
      expect(calls, 2);
    },
  );
}
