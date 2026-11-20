// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'initial_request_live_readiness.dart';
import 'live_model_config.dart' show liveModelId;

Map<String, Object?> _health() => {
  'status': 'ready',
  'phase': 'idle',
  'backend': 'mlx',
  'device': 'metal',
  'model': liveModelId,
  'streaming': true,
};
Map<String, Object?> _limits() => {
  'schema_version': 1,
  'max_input_tokens': 4096,
  'max_output_tokens': 4096,
  'checkpoint_context_tokens': null,
};
Map<String, Object?> _inventory({Object? id = liveModelId, Object? limits}) => {
  'data': [
    {'id': id, 'asg_request_limits': limits ?? _limits()},
  ],
};

class _Client extends http.BaseClient {
  _Client(this.respond);
  final Future<http.StreamedResponse> Function(http.BaseRequest) respond;
  final requests = <http.BaseRequest>[];
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    requests.add(request);
    return respond(request);
  }

  @override
  void close() => closed = true;
}

http.StreamedResponse _reply(Object? value, {int status = 200}) =>
    http.StreamedResponse(Stream.value(utf8.encode(jsonEncode(value))), status);

void main() {
  test(
    'accepts exact idle bridge assertions with the source request budget',
    () {
      requireInitialRequestLiveReadiness(_health(), _inventory());
    },
  );

  for (final changed in <String, Object?>{
    'status': 'loading',
    'phase': 'thinking',
    'backend': 'torch',
    'device': 'cpu',
    'model': 'different-model',
    'streaming': false,
  }.entries) {
    test('refuses ${changed.key} mismatch despite a matching inventory', () {
      final health = _health()..[changed.key] = changed.value;
      expect(
        () => requireInitialRequestLiveReadiness(health, _inventory()),
        throwsStateError,
      );
      health.remove(changed.key);
      expect(
        () => requireInitialRequestLiveReadiness(health, _inventory()),
        throwsStateError,
      );
    });
  }

  test('missing or malformed endpoint replies cannot authorize generation', () {
    for (final invalid in <Object?>[
      null,
      'ready',
      [],
      {'data': []},
    ]) {
      expect(
        () => requireInitialRequestLiveReadiness(invalid, _inventory()),
        throwsStateError,
      );
      expect(
        () => requireInitialRequestLiveReadiness(_health(), invalid),
        throwsStateError,
      );
    }
    expect(
      () => requireInitialRequestLiveReadiness(
        _health(),
        _inventory(id: 'different-model'),
      ),
      throwsStateError,
    );
    final ambiguous = _inventory();
    (ambiguous['data']! as List).add({'id': liveModelId});
    expect(
      () => requireInitialRequestLiveReadiness(_health(), ambiguous),
      throwsStateError,
    );
  });

  test('absent, insufficient or loosely typed limits refuse the live gate', () {
    for (final key in [
      'schema_version',
      'max_input_tokens',
      'max_output_tokens',
    ]) {
      for (final value in <Object?>[null, '4096', 4096.0, 2048, false]) {
        final limits = _limits()..[key] = value;
        expect(
          () => requireInitialRequestLiveReadiness(
            _health(),
            _inventory(limits: limits),
          ),
          throwsStateError,
          reason: '$key must be the exact typed bridge policy',
        );
      }
    }
  });
  test(
    'fixed-route reads are GET only, refuse redirects and close their client',
    () async {
      final client = _Client(
        (r) async => _reply(r.url.path == '/health' ? _health() : _inventory()),
      );
      await checkInitialRequestLiveReadiness(createClient: () => client);
      expect(client.requests.map((r) => r.url.toString()), [
        'http://127.0.0.1:8765/health',
        'http://127.0.0.1:8765/v1/models',
      ]);
      expect(
        client.requests.every((r) => r.method == 'GET' && !r.followRedirects),
        isTrue,
      );
      expect(client.closed, isTrue);
    },
  );

  for (final status in [302, 503]) {
    test('HTTP $status fails without retry or another request', () async {
      final client = _Client((_) async => _reply({}, status: status));
      await expectLater(
        checkInitialRequestLiveReadiness(createClient: () => client),
        throwsStateError,
      );
      expect(client.requests, hasLength(1));
      expect(client.closed, isTrue);
    });
  }
  test(
    'matching health cannot hide a different advertised model over HTTP',
    () async {
      final client = _Client(
        (r) async => _reply(
          r.url.path == '/health'
              ? _health()
              : _inventory(id: 'different-model'),
        ),
      );
      await expectLater(
        checkInitialRequestLiveReadiness(createClient: () => client),
        throwsStateError,
      );
      expect(client.requests.map((r) => r.url.path), ['/health', '/v1/models']);
      expect(client.requests.every((r) => r.method == 'GET'), isTrue);
      expect(client.closed, isTrue);
    },
  );

  test(
    'invalid JSON and oversized streams fail closed and close the client',
    () async {
      for (final bytes in [utf8.encode('not json'), List.filled(16385, 32)]) {
        final client = _Client(
          (_) async => http.StreamedResponse(Stream.value(bytes), 200),
        );
        await expectLater(
          checkInitialRequestLiveReadiness(createClient: () => client),
          throwsA(anyOf(isA<FormatException>(), isA<StateError>())),
        );
        expect(client.requests, hasLength(1));
        expect(client.closed, isTrue);
      }
    },
  );
  test(
    'unavailable transport and stalled headers are bounded with no retries',
    () async {
      final stalled = Completer<http.StreamedResponse>();
      for (final pending in [
        Future<http.StreamedResponse>.error(
          http.ClientException('supplied unavailable'),
        ),
        stalled.future,
      ]) {
        final client = _Client((_) => pending);
        await expectLater(
          checkInitialRequestLiveReadiness(
            createClient: () => client,
            timeout: const Duration(milliseconds: 20),
          ),
          throwsA(anyOf(isA<http.ClientException>(), isA<TimeoutException>())),
        );
        expect(client.requests, hasLength(1));
        expect(client.closed, isTrue);
      }
      stalled.complete(_reply(_health()));
    },
  );
  test('a stalled response body is bounded and its client is closed', () async {
    final body = StreamController<List<int>>();
    final client = _Client(
      (_) async => http.StreamedResponse(body.stream, 200),
    );
    await expectLater(
      checkInitialRequestLiveReadiness(
        createClient: () => client,
        timeout: const Duration(milliseconds: 20),
      ),
      throwsA(isA<TimeoutException>()),
    );
    expect(client.closed, isTrue);
    expect(client.requests, hasLength(1));
    await body.close();
  });
}
