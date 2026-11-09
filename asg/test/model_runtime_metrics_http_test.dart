// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/model_settings_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'model_connection_presets_test.dart' show PresetRecords;

const metrics = {
  'finish_reason': 'stop',
  'prompt_tokens': 17,
  'completion_tokens': 2,
  'tokens_per_second': 12.5,
  'peak_memory_gb': 6.25,
  'private_debug': 'never display this',
};
Map<String, Object> response({Object? reported = metrics}) => {
  'model': 'Qwen3.8-27B-4bit',
  'choices': [
    {
      'message': {'content': 'Ready'},
      'finish_reason': 'stop',
    },
  ],
  'metrics': ?reported,
};
String event(Object value) => 'data: ${jsonEncode(value)}\n\n';
String streamStart({String reason = 'stop'}) =>
    event({
      'model': 'Qwen3.8-27B-4bit',
      'choices': [
        {
          'delta': {'content': 'Ready'},
        },
      ],
    }) +
    event({
      'choices': [
        {'delta': <String, Object>{}, 'finish_reason': reason},
      ],
      'metrics': metrics,
    });

void main() {
  test('actual HTTP telemetry saves only explicitly with matching test observation', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    addTearDown(() => server.close(force: true));
    var requests = 0;
    var json = false;
    var hold = false;
    final held = Completer<void>();
    final received = Completer<void>();
    server.listen((request) async {
      requests++;
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      expect(body['max_tokens'], 256);
      if (json) {
        request.response.write(jsonEncode(response()));
      } else {
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(streamStart());
        if (hold) {
          await request.response.flush();
          received.complete();
          await held.future;
        } else {
          request.response.write('data: [DONE]\n\n');
        }
      }
      await request.response.close();
    });
    final config = LocalModelConfig(
      baseUrl: 'http://127.0.0.1:${server.port}/v1',
    );
    final records = PresetRecords();
    final controller = ModelSettingsController(ModelSettingsStore(records));
    addTearDown(controller.dispose);
    await controller.savePreset('Local', config);
    controller.selectPreset('Local');
    for (final useJson in [false, true]) {
      json = useJson;
      await controller.test(config);
      expect(controller.runtimeMetrics?.tokensPerSecond, 12.5);
      expect(controller.status, isNot(contains('never display')));
      final beforeSave = records.values.values.join();
      if (!beforeSave.contains('runtimeMetrics')) {
        expect(beforeSave, isNot(contains('tokens_per_second')));
      }
      final before = records.values[ModelSettingsStore.presetsKey];
      records.fail = true;
      await controller.saveTestObservation(config);
      expect(records.values[ModelSettingsStore.presetsKey], before);
      expect(controller.canSaveTestObservation(config), isTrue);
      records.fail = false;
      await controller.saveTestObservation(config);
      expect(
        ModelSettingsStore(records)
            .loadPresets()
            .single
            .testObservation!
            .runtimeMetrics!
            .tokensPerSecond,
        12.5,
      );
      expect(
        ModelSettingsStore(records)
            .loadPresets()
            .single
            .testObservation!
            .responseModel,
        'Qwen3.8-27B-4bit',
      );
      expect(records.values.values.join(), isNot(contains('private_debug')));
      expect(records.values.values.join(), isNot(contains('never display')));
      controller.connectionDraftChanged();
      expect(controller.runtimeMetrics, isNull);
    }
    expect(requests, 2);
    final reopened = ModelSettingsController(ModelSettingsStore(records));
    expect(reopened.runtimeMetrics, isNull);
    expect(
      reopened.presets.single.testObservation!.runtimeMetrics!.promptTokens,
      17,
    );
    reopened.dispose();
    // A format failure cannot expose metrics from an otherwise valid reply.
    await controller.test(config, jsonFormat: true);
    expect(controller.runtimeMetrics, isNull);
    expect(controller.status, contains('JSON format test failed'));
    await controller.test(config);
    expect(controller.runtimeMetrics, isNotNull);
    json = false;
    hold = true;
    final pending = controller.test(config);
    expect(controller.runtimeMetrics, isNull);
    await received.future;
    expect(controller.runtimeMetrics, isNull);
    controller.stopTest();
    await pending;
    expect(controller.runtimeMetrics, isNull);
    held.complete();
    // Invalid configuration must not reuse the prior successful observation.
    await controller.test(const LocalModelConfig(model: ''));
    expect(controller.runtimeMetrics, isNull);
  });
}
