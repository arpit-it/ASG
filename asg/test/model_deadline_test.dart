// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/local_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

class TrackingClient extends http.BaseClient {
  TrackingClient(this.delegate);
  final http.Client delegate;
  bool closed = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) =>
      delegate.send(request);

  @override
  void close() {
    closed = true;
    delegate.close();
  }
}

final deadlineError = isA<TimeoutException>().having(
  (e) => e.message,
  'message',
  contains('total generation limit'),
);

void main() {
  test(
    'absolute deadline bounds stalled SSE, JSON and rejection bodies',
    () async {
      for (final (contentType, status) in [
        ('text/event-stream', 200),
        ('application/json', 200),
        ('text/plain', 500),
      ]) {
        final chunks = StreamController<List<int>>();
        final client = TrackingClient(
          MockClient.streaming(
            (request, body) async => http.StreamedResponse(
              chunks.stream,
              status,
              headers: {'content-type': contentType},
            ),
          ),
        );
        final provider = LocalModelProvider(
          const LocalModelConfig(),
          client: client,
          totalTimeout: const Duration(milliseconds: 30),
          idleTimeout: const Duration(seconds: 5),
        );
        await expectLater(
          provider.generate('Hi').join().timeout(const Duration(seconds: 2)),
          throwsA(deadlineError),
        );
        expect(client.closed, true);
        await chunks.close();
        await provider.cancel();
      }
    },
  );

  test('absolute deadline also bounds waiting for response headers', () async {
    final response = Completer<http.StreamedResponse>();
    final client = TrackingClient(
      MockClient.streaming((request, body) => response.future),
    );
    final provider = LocalModelProvider(
      const LocalModelConfig(),
      client: client,
      totalTimeout: const Duration(milliseconds: 30),
    );
    await expectLater(
      provider.generate('Hi').join().timeout(const Duration(seconds: 2)),
      throwsA(deadlineError),
    );
    expect(client.closed, true);
    response.complete(http.StreamedResponse(Stream.value([]), 200));
    await provider.cancel();
  });

  test('heartbeat activity cannot extend the absolute deadline', () async {
    final chunks = StreamController<List<int>>();
    final heartbeat = Timer.periodic(const Duration(milliseconds: 5), (_) {
      chunks.add(utf8.encode('event: ping\ndata: {}\n\n'));
    });
    final client = TrackingClient(
      MockClient.streaming(
        (request, body) async => http.StreamedResponse(
          chunks.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    final provider = LocalModelProvider(
      const LocalModelConfig(),
      client: client,
      totalTimeout: const Duration(milliseconds: 60),
      idleTimeout: const Duration(seconds: 5),
    );
    try {
      await expectLater(
        provider.generate('Hi').join().timeout(const Duration(seconds: 2)),
        throwsA(deadlineError),
      );
      expect(client.closed, true);
    } finally {
      heartbeat.cancel();
      await chunks.close();
      await provider.cancel();
    }
  });

  test('completed JSON replies cancel deadline and retain content', () async {
    final client = TrackingClient(
      MockClient(
        (request) async => http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'Complete'},
                'finish_reason': 'stop',
              },
            ],
          }),
          200,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    final provider = LocalModelProvider(
      const LocalModelConfig(),
      client: client,
      totalTimeout: const Duration(milliseconds: 60),
    );
    expect(await provider.generate('Hi').join(), 'Complete');
    await Future<void>.delayed(const Duration(milliseconds: 90));
    expect(client.closed, false);
    await provider.cancel();
    expect(client.closed, true);
  });

  test('listener cancellation clears deadline and explicit cancellation closes transport', () async {
    final chunks = StreamController<List<int>>.broadcast();
    final client = TrackingClient(
      MockClient.streaming(
        (request, body) async => http.StreamedResponse(
          chunks.stream,
          200,
          headers: {'content-type': 'text/event-stream'},
        ),
      ),
    );
    final provider = LocalModelProvider(
      const LocalModelConfig(),
      client: client,
      totalTimeout: const Duration(milliseconds: 60),
    );
    final firstEvent = Completer<void>();
    final subscription = provider.generateEvents('Hi').listen((_) {
      if (!firstEvent.isCompleted) firstEvent.complete();
    });
    await firstEvent.future;
    await subscription.cancel();
    await provider.cancel();
    await chunks.close();
    expect(client.closed, true);
    await Future<void>.delayed(const Duration(milliseconds: 90));
  });
}
