// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/model_settings_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/advertised_request_limits.dart';
import 'package:asg/services/model_inventory.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:asg/views/model_settings.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'model_connection_presets_test.dart' show PresetRecords;

class _RealHttp extends HttpOverrides {}

Map<String, Object?> limits([Object? context = 8192]) => {
  'schema_version': 1,
  'max_input_tokens': 4096,
  'max_output_tokens': 4096,
  'checkpoint_context_tokens': context,
};

void main() {
  test(
    'exact selected inventory limits are assertions and never applied',
    () async {
      for (final context in [null, 8192]) {
        final config = const LocalModelConfig(
          model: 'chosen',
          chatOutputTokens: 512,
        );
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                {'id': 'other', 'asg_request_limits': 'private sentinel'},
                {'id': 'chosen', 'asg_request_limits': limits(context)},
              ],
            }),
            200,
          ),
        );
        addTearDown(client.close);
        final result = await ModelInventory.check(config, client: client);
        expect(result, contains('4096 input tokens, 4096 output tokens'));
        expect(
          result,
          contains(
            context == null
                ? 'total context is unknown'
                : 'total context: 8192',
          ),
        );
        expect(result, contains('do not verify usable capacity'));
        expect(result, contains('Requests and settings are unchanged'));
        expect(result, isNot(contains('sentinel')));
        expect(config.chatOutputTokens, 512);
      }
    },
  );
  test(
    'malformed selected limits fail privately and valid retry recovers',
    () async {
      final invalid = <Object?>[
        null,
        [],
        'sentinel',
        {},
        {...limits(), 'schema_version': 1.0},
        {...limits(), 'schema_version': 2},
        {...limits(), 'private': 'sentinel'},
        {...limits()}..remove('checkpoint_context_tokens'),
        for (final field in [
          'max_input_tokens',
          'max_output_tokens',
          'checkpoint_context_tokens',
        ])
          for (final value in [true, '8192', 0, -1, 1.5, 9007199254740992])
            {...limits(), field: value},
        {...limits(), 'max_input_tokens': null},
        {...limits(), 'max_output_tokens': null},
      ];
      for (final metadata in invalid) {
        var retry = false;
        final client = MockClient(
          (_) async => http.Response(
            jsonEncode({
              'data': [
                {
                  'id': 'chosen',
                  'asg_request_limits': retry ? limits() : metadata,
                },
              ],
            }),
            200,
          ),
        );
        addTearDown(client.close);
        final result = await ModelInventory.check(
          const LocalModelConfig(model: 'chosen'),
          client: client,
        );
        expect(result, contains('invalid or exceed'), reason: '$metadata');
        expect(result, isNot(contains('sentinel')));
        retry = true;
        expect(
          await ModelInventory.check(
            const LocalModelConfig(model: 'chosen'),
            client: client,
          ),
          contains('total context: 8192'),
        );
      }
    },
  );

  test(
    'actual HTTP uses draft base models route without inference',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final serving = server.first.then((request) async {
        expect(request.method, 'GET');
        expect(request.uri.path, '/custom/v1/models');
        expect(await utf8.decoder.bind(request).join(), isEmpty);
        request.response.write(
          jsonEncode({
            'data': [
              {'id': 'chosen', 'asg_request_limits': limits()},
            ],
          }),
        );
        await request.response.close();
      });
      final result = await ModelInventory.inspect(
        LocalModelConfig(
          baseUrl: 'http://127.0.0.1:${server.port}/custom/v1',
          model: 'chosen',
        ),
      );
      await serving;
      expect(result, contains('advertises the exact'));
      expect(result, contains('context limits'));
      expect(result, contains('total context: 8192'));
      expect(result, contains('unverified'));
    }, _RealHttp()),
  );
  test('membership exact and arbitrary metadata private', () async {
    for (final id in ['chosen', 'Chosen', 'other']) {
      final client = MockClient((request) async {
        expect(request.followRedirects, isFalse);
        return http.Response(
          jsonEncode({
            'data': [
              {'id': id, 'private': 'sentinel'},
            ],
          }),
          200,
        );
      });
      addTearDown(client.close);
      final result = await ModelInventory.check(
        const LocalModelConfig(model: 'chosen'),
        client: client,
      );
      expect(result.contains('does not advertise'), id != 'chosen');
      expect(result, isNot(contains('sentinel')));
    }
  });
  test('invalid duplicate oversized metadata fails privately', () async {
    for (final body in [
      'sentinel',
      '[]',
      '{}',
      '{"data":{}}',
      '{"data":[{"id":null}]}',
      '{"data":[{"id":""}]}',
      '{"data":[{"id":" a"}]}',
      '{"data":[{"id":"a\\n"}]}',
      '{"data":[{"id":"a"},{"id":"a"}]}',
      jsonEncode({
        'data': List.generate(1001, (i) => {'id': '$i'}),
      }),
      jsonEncode({
        'data': [
          {'id': 'a' * 257},
        ],
      }),
      ' ' * 65537,
    ]) {
      final client = MockClient((_) async => http.Response(body, 200));
      addTearDown(client.close);
      final result = await ModelInventory.check(
        const LocalModelConfig(),
        client: client,
      );
      expect(result, contains('invalid or exceed'));
      expect(result, isNot(contains('sentinel')));
    }
  });
  test('HTTP failure redirect timeout and offline remain private', () async {
    for (final status in [302, 404, 503]) {
      final client = MockClient((_) async => http.Response('sentinel', status));
      addTearDown(client.close);
      expect(
        await ModelInventory.check(const LocalModelConfig(), client: client),
        contains('unavailable'),
      );
    }
    for (final error in [
      TimeoutException('sentinel'),
      http.ClientException('sentinel'),
    ]) {
      final client = MockClient((_) async => throw error);
      addTearDown(client.close);
      final result = await ModelInventory.check(
        const LocalModelConfig(),
        client: client,
      );
      expect(
        result,
        contains(error is TimeoutException ? 'timed out' : 'not reachable'),
      );
      expect(result, isNot(contains('sentinel')));
    }
  });
  test('remote credentialed and query destinations never send', () async {
    final client = MockClient((_) async => fail('must not send'));
    addTearDown(client.close);
    for (final url in [
      'https://example.com/v1',
      'http://u:p@localhost/v1',
      'http://localhost/v1?secret=x',
    ]) {
      expect(
        await ModelInventory.check(
          LocalModelConfig(baseUrl: url),
          client: client,
        ),
        contains('invalid'),
      );
    }
  });
  test('draft only; busy guard and stale observation clearing', () async {
    final records = PresetRecords();
    final pending = Completer<String>();
    var calls = 0;
    final c = ModelSettingsController(
      ModelSettingsStore(records),
      inspectInventory: (config) {
        expect(config.model, 'draft');
        calls++;
        return pending.future;
      },
    );
    final active = c.inspectInventory(const LocalModelConfig(model: 'draft'));
    await c.inspectInventory(const LocalModelConfig());
    await c.save(const LocalModelConfig(model: 'changed'));
    expect(calls, 1);
    expect(c.busy, isTrue);
    pending.complete('observed');
    await active;
    expect(c.inventoryStatus, 'observed');
    expect(records.values, isEmpty);
    c.clearInventory();
    expect(c.inventoryStatus, isNull);
    c.dispose();
    await c.inspectInventory(const LocalModelConfig());
    expect(calls, 1);
  });
  testWidgets('narrow enlarged draft inspection clears after ID edit', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = PresetRecords();
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: ModelSettings(
              store: ModelSettingsStore(records),
              inspectInventory: (_) async =>
                  'Observed draft only ${AdvertisedRequestLimits.fromJson(limits()).description}',
            ),
          ),
        ),
      ),
    );
    final inspect = find.text('Inspect draft model ID');
    await tester.ensureVisible(inspect);
    await tester.pumpAndSettle();
    await tester.tap(inspect);
    await tester.pumpAndSettle();
    expect(find.textContaining('Observed draft only'), findsOneWidget);
    final field = find.widgetWithText(TextField, 'Exact server model ID');
    await tester.ensureVisible(field);
    await tester.pumpAndSettle();
    await tester.enterText(field, 'other');
    await tester.pumpAndSettle();
    expect(find.textContaining('Observed draft only'), findsNothing);
    expect(records.values, isEmpty);
    expect(tester.takeException(), isNull);
  });
  test('disposal suppresses late observation', () async {
    final pending = Completer<String>();
    final c = ModelSettingsController(
      ModelSettingsStore(PresetRecords()),
      inspectInventory: (_) => pending.future,
    );
    var notifications = 0;
    c.addListener(() => notifications++);
    final active = c.inspectInventory(const LocalModelConfig());
    c.dispose();
    final before = notifications;
    pending.complete('late');
    await active;
    expect(c.inventoryStatus, isNot('late'));
    expect(notifications, before);
  });
}
