// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/model_settings_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/services/local_model.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final invalidIds = [
    '',
    '  ',
    for (var code = 0; code < 32; code++) 'model${String.fromCharCode(code)}id',
    'model\u007fid',
    'm' * 4097,
  ];
  test(
    'invalid IDs cannot replace settings or create test providers',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = ModelSettingsStore.fromPreferences(preferences);
      await store.save(const LocalModelConfig(model: 'working'));
      final original = preferences.getString('studio.localModel.v1');
      var providers = 0;
      final controller = ModelSettingsController(
        store,
        createProvider: (_) {
          providers++;
          throw StateError('Invalid ID reached provider factory');
        },
      );
      addTearDown(controller.dispose);
      for (final id in invalidIds) {
        final config = LocalModelConfig(model: id);
        await expectLater(store.save(config), throwsFormatException);
        await controller.test(config);
        expect(controller.status, contains('Invalid connection settings'));
        expect(controller.busy, isFalse);
        expect(preferences.getString('studio.localModel.v1'), original);
      }
      expect(providers, 0);
      await controller.save(const LocalModelConfig(model: 'recovered'));
      expect(store.load().model, 'recovered');
    },
  );
  test(
    'invalid saved IDs remain intact and surface as load failures',
    () async {
      for (final id in invalidIds) {
        final raw = jsonEncode({
          'baseUrl': 'http://127.0.0.1:8765/v1',
          'model': id,
        });
        SharedPreferences.setMockInitialValues({'studio.localModel.v1': raw});
        final preferences = await SharedPreferences.getInstance();
        final store = ModelSettingsStore.fromPreferences(preferences);
        expect(store.load, throwsFormatException);
        final controller = ModelSettingsController(store);
        controller.initial;
        expect(controller.settingsLoadFailed, isTrue);
        expect(
          controller.status,
          contains('Records have not been overwritten'),
        );
        await controller.save(const LocalModelConfig(model: 'replacement'));
        expect(preferences.getString('studio.localModel.v1'), raw);
        controller.dispose();
      }
    },
  );
  test(
    'actual HTTP refuses invalid IDs and retains exact valid identity',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final received = <String>[];
      server.listen((request) async {
        final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
        final id = body['model'] as String;
        received.add(id);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'model': id,
            'choices': [
              {
                'message': {'content': 'Ready'},
                'finish_reason': 'stop',
              },
            ],
          }),
        );
        await request.response.close();
      });
      final url = 'http://127.0.0.1:${server.port}/v1';
      for (final id in invalidIds) {
        final provider = LocalModelProvider(
          LocalModelConfig(baseUrl: url, model: id),
        );
        await expectLater(
          provider.generate('private instruction').join(),
          throwsStateError,
        );
        await provider.cancel();
      }
      expect(received, isEmpty);
      for (final id in ['m' * 4096, 'org/model:版本-4bit', ' exact-id ']) {
        final config = LocalModelConfig(baseUrl: url, model: id);
        final provider = LocalModelProvider(config);
        expect(await provider.generate('Hello').join(), 'Ready');
        expect(provider.completedResponseModel, id);
        expect(ModelRequestProvenance.fromConfig(config).model, id);
        await provider.cancel();
      }
      expect(received, ['m' * 4096, 'org/model:版本-4bit', ' exact-id ']);
    },
  );
}
