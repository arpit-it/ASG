// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
@TestOn('browser')
library;

import 'dart:convert';

import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/local_model.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

const port = int.fromEnvironment('ASG_BROWSER_TRANSPORT_PORT');
const prompt = 'Disposable browser transport probe';

void main() {
  test(
    'actual browser refuses redirects without forwarding and retries JSON/SSE',
    () async {
      Future<String> generate(String path) async {
        final provider = LocalModelProvider(
          LocalModelConfig(
            baseUrl: 'http://127.0.0.1:$port/$path/v1',
            model: 'browser-selected',
          ),
          totalTimeout: const Duration(seconds: 10),
        );
        try {
          return await provider.generate(prompt).join();
        } finally {
          await provider.cancel();
        }
      }

      // A working direct request proves that CORS/connectivity is not the cause
      // of the following failures. The server independently validates payloads.
      expect(await generate('json'), 'Ready');
      for (final code in [301, 302, 303, 307, 308]) {
        await expectLater(
          generate('$code'),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'private actionable guidance',
              allOf(
                contains('Check'),
                contains('retry'),
                isNot(contains('private-target')),
                isNot(contains(prompt)),
                isNot(contains('$port')),
              ),
            ),
          ),
        );
      }
      expect(await generate('json'), 'Ready');
      expect(await generate('sse'), 'Stream ready');
      final client = http.Client();
      addTearDown(client.close);
      final response = await client
          .get(Uri.parse('http://127.0.0.1:$port/stats'))
          .timeout(const Duration(seconds: 5));
      expect(response.statusCode, 200);
      expect(jsonDecode(response.body), {
        'counts': {
          '301': 1,
          '302': 1,
          '303': 1,
          '307': 1,
          '308': 1,
          'json': 2,
          'sse': 1,
          'target': 0,
        },
        'failures': [],
      });
    },
    skip: port == 0
        ? 'Run python3 tools/test_browser_model_transport.py'
        : false,
  );
}
