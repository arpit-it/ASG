// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';
import 'dart:async';

import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/local_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('redirect refusal does not wait for body or expose Location', () async {
    for (final status in [300, 301, 302, 303, 304, 307, 308, 399]) {
      final body = StreamController<List<int>>();
      final provider = LocalModelProvider(
        const LocalModelConfig(),
        client: MockClient.streaming((request, stream) async {
          expect(request.followRedirects, isFalse);
          await stream.drain<void>();
          return http.StreamedResponse(
            body.stream,
            status,
            headers: {'location': 'https://private.invalid/secret'},
          );
        }),
      );
      try {
        await expectLater(
          provider
              .generate('Private instruction')
              .join()
              .timeout(const Duration(seconds: 1)),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'private guidance',
              allOf(
                contains('redirects are refused'),
                contains('selected local endpoint'),
                isNot(contains('secret')),
                isNot(contains('Private instruction')),
              ),
            ),
          ),
        );
      } finally {
        await provider.cancel();
        unawaited(body.close());
      }
    }
  });
  test(
    'selected native connection refuses redirects and direct retry works',
    () async {
      final target = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final source = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() async {
        await source.close(force: true);
        await target.close(force: true);
      });
      var targetRequests = 0;
      target.listen((request) async {
        targetRequests++;
        await request.drain<void>();
        request.response.write(
          '{"choices":[{"message":{"content":"Wrong source"}}]}',
        );
        await request.response.close();
      });
      var status = 303;
      source.listen((request) async {
        expect(request.method, 'POST');
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        expect(body['model'], 'selected');
        expect(body['messages'][0]['content'], 'Private instruction');
        if (status != 200) {
          request.response.statusCode = status;
          request.response.headers.set(
            'location',
            'http://127.0.0.1:${target.port}/private-target',
          );
        } else {
          request.response.write(
            '{"choices":[{"message":{"content":"Ready"}}]}',
          );
        }
        await request.response.close();
      });
      for (final code in [303, 301, 302, 307, 308]) {
        status = code;
        final provider = LocalModelProvider(
          LocalModelConfig(
            baseUrl: 'http://127.0.0.1:${source.port}/v1',
            model: 'selected',
          ),
        );
        try {
          await expectLater(
            provider.generate('Private instruction').join(),
            throwsStateError,
          );
          expect(
            targetRequests,
            0,
            reason: 'redirect $code must not reach another URL',
          );
        } finally {
          await provider.cancel();
        }
      }
      status = 200;
      final retry = LocalModelProvider(
        LocalModelConfig(
          baseUrl: 'http://127.0.0.1:${source.port}/v1',
          model: 'selected',
        ),
      );
      addTearDown(retry.cancel);
      expect(await retry.generate('Private instruction').join(), 'Ready');
      expect(targetRequests, 0);
    },
  );
}
