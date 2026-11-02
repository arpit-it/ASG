// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/model_settings_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_format_probe.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test(
    'actual HTTP JSON format probe routes draft and fixed budget; retry',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = ModelSettingsStore.fromPreferences(
        await SharedPreferences.getInstance(),
      );
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        expect(request.uri.path, '/v1/chat/completions');
        final body = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        requests.add(body);
        if (requests.length == 1) {
          request.response.headers.contentType = ContentType.json;
          request.response.write(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '{"asg_probe":"private-marker"}'},
                },
              ],
            }),
          );
        } else {
          request.response.headers.set('content-type', 'text/event-stream');
          for (final text in ['{"asg_probe":', '"ok"}']) {
            request.response.write(
              'data: ${jsonEncode({
                'choices': [
                  {
                    'delta': {'content': text},
                  },
                ],
              })}\n\n',
            );
          }
          request.response.write('data: [DONE]\n\n');
        }
        await request.response.close();
      });
      final c = ModelSettingsController(store);
      addTearDown(c.dispose);
      final draft = LocalModelConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'chosen-model',
        chatOutputTokens: 2048,
      );
      await c.test(draft, jsonFormat: true);
      expect(c.status, contains('JSON format test failed'));
      expect(c.status, isNot(contains('Client-observed first text:')));
      expect(c.status, isNot(contains('private-marker')));
      await c.test(draft, jsonFormat: true);
      expect(
        c.status,
        contains('expected JSON object in one completed response'),
      );
      expect(c.status, contains('Requested model ID: chosen-model'));
      expect(
        c.status,
        matches(
          RegExp(r'first text: [0-9]+ ms; completed response: [0-9]+ ms'),
        ),
      );
      expect(requests, hasLength(2));
      for (final request in requests) {
        expect(request['model'], 'chosen-model');
        expect(request['max_tokens'], 256);
        expect(request['stream'], isTrue);
        expect(request['messages'], [
          {'role': 'user', 'content': ModelFormatProbe.prompt},
        ]);
        expect(request.containsKey('response_format'), isFalse);
      }
      expect(store.load().model, const LocalModelConfig().model);
      expect(store.loadPresets(), isEmpty);
    },
  );
}
