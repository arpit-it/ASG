// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/ask_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_connection_preset.dart';
import 'package:asg/services/ask_store.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/views/ask_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_controller_test.dart' show AskRecords, AskProvider, tick;

const preset = ModelConnectionPreset(
  name: 'Local coding',
  config: LocalModelConfig(model: 'selected-model', chatOutputTokens: 512),
);

void main() {
  test(
    'chat snapshot survives preset deletion, global changes and reopen',
    () async {
      final records = AskRecords();
      final settings = ModelSettingsStore(records);
      await settings.savePresets([preset]);
      final configs = <LocalModelConfig>[];
      AskProvider answer(LocalModelConfig config) {
        configs.add(config);
        return AskProvider()
          ..stream.add('answer')
          ..stream.close();
      }

      var controller = AskController(AskStore(records), createProvider: answer)
        ..load();
      await controller.choosePreset(controller.presets.single);
      expect(records.getString(AskStore.key), isNull);
      await controller.send('selected question');
      await settings.savePresets([]);
      await settings.save(const LocalModelConfig(model: 'global-new'));
      controller.dispose();
      controller = AskController(AskStore(records), createProvider: answer)
        ..load();
      expect(controller.connectionPreset!.name, preset.name);
      expect(controller.presets, isEmpty);
      await controller.send('selected again');
      controller.select(null);
      expect(controller.connectionPreset, isNull);
      await controller.send('global question');
      expect(configs.map((c) => c.model), [
        'selected-model',
        'selected-model',
        'global-new',
      ]);
      controller.select('ask-1');
      expect(controller.messages.last.modelRequest!.model, 'selected-model');
      await controller.choosePreset(null);
      await controller.send('global now');
      expect(configs.last.model, 'global-new');
      expect(controller.history.length, 2);
      controller.dispose();
    },
  );

  test('failed selection write retains messages and old selection; busy excludes sends', () async {
    final records = AskRecords();
    await ModelSettingsStore(records).savePresets([preset]);
    final controller = AskController(
      AskStore(records),
      createProvider: (_) => AskProvider()
        ..stream.add('answer')
        ..stream.close(),
    )..load();
    await controller.send('question');
    final saved = records.getString(AskStore.key);
    records.gate = Completer<void>();
    records.failWrite = records.writes + 1;
    final selecting = controller.choosePreset(controller.presets.single);
    expect(controller.busy, isTrue);
    expect(await controller.send('overlap'), isFalse);
    controller.select(null);
    expect(controller.selectedId, 'ask-1');
    records.gate!.complete();
    await selecting;
    expect(controller.connectionPreset, isNull);
    expect(records.getString(AskStore.key), saved);
    expect(controller.error, contains('Previous selection'));
    records.gate = null;
    records.failWrite = null;
    await controller.choosePreset(controller.presets.single);
    expect(controller.connectionPreset!.name, preset.name);
    controller.dispose();
  });

  test('switch blocked during request and completed-answer recovery; retry keeps identity', () async {
    final records = AskRecords();
    await ModelSettingsStore(records).savePresets([preset]);
    final provider = AskProvider();
    final controller = AskController(
      AskStore(records),
      createProvider: (_) => provider,
    )..load();
    await controller.choosePreset(controller.presets.single);
    records.failWrite = records.writes + 2;
    final sending = controller.send('question');
    await tick();
    await controller.choosePreset(null);
    expect(controller.connectionPreset!.name, preset.name);
    provider.stream.add('answer');
    await provider.stream.close();
    await sending;
    expect(controller.unsavedAnswer, 'answer');
    await controller.choosePreset(null);
    expect(controller.connectionPreset!.name, preset.name);
    records.failWrite = null;
    await controller.retrySaving();
    expect(controller.messages.last.modelRequest!.model, 'selected-model');
    expect(provider.prompts.length, 1);
    controller.dispose();
    await controller.choosePreset(null);
    expect(controller.connectionPreset!.name, preset.name);
  });

  test('corrupt selection fails closed and corrupt presets retain selected snapshot', () async {
    final records = AskRecords();
    await ModelSettingsStore(records).savePresets([preset]);
    final controller = AskController(
      AskStore(records),
      createProvider: (_) => AskProvider()
        ..stream.add('answer')
        ..stream.close(),
    )..load();
    await controller.choosePreset(controller.presets.single);
    await controller.send('question');
    records.values[ModelSettingsStore.presetsKey] = '{broken';
    controller.refreshPresets();
    expect(controller.presetError, isNotNull);
    expect(controller.connectionPreset!.config.model, 'selected-model');
    final data =
        jsonDecode(records.getString(AskStore.key)!) as Map<String, dynamic>;
    (data['conversations'] as List).single['connectionPreset'] = null;
    final corrupt = jsonEncode(data);
    records.values[AskStore.key] = corrupt;
    final reopened = AskController(AskStore(records))..load();
    expect(reopened.ready, isFalse);
    expect(await reopened.send('overwrite'), isFalse);
    expect(records.getString(AskStore.key), corrupt);
    controller.dispose();
    reopened.dispose();
  });

  test(
    'actual HTTP request uses selected endpoint model and ceiling',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final observed = Completer<Map<String, dynamic>>();
      server.listen((request) async {
        observed.complete(
          jsonDecode(await utf8.decoder.bind(request).join())
              as Map<String, dynamic>,
        );
        request.response.headers.contentType = ContentType(
          'text',
          'event-stream',
        );
        request.response.write(
          'data: {"choices":[{"delta":{"content":"answer"}}]}\n\ndata: [DONE]\n\n',
        );
        await request.response.close();
      });
      final records = AskRecords();
      await ModelSettingsStore(records).savePresets([
        ModelConnectionPreset(
          name: 'HTTP',
          config: LocalModelConfig(
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            model: 'http-selected',
            chatOutputTokens: 1024,
          ),
        ),
      ]);
      final controller = AskController(AskStore(records))..load();
      try {
        await controller.choosePreset(controller.presets.single);
        await controller.send('question');
        final body = await observed.future.timeout(const Duration(seconds: 5));
        expect(body['model'], 'http-selected');
        expect(body['max_tokens'], 1024);
        expect(controller.messages.last.modelRequest!.model, body['model']);
        expect(
          controller.messages.last.modelRequest!.outputTokens,
          body['max_tokens'],
        );
      } finally {
        controller.dispose();
        await server.close(force: true);
        HttpOverrides.global = previous;
      }
    },
  );

  testWidgets('narrow enlarged Ask selection is scrollable and interactive', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = AskRecords();
    await ModelSettingsStore(records).savePresets([preset]);
    final controller = AskController(AskStore(records));
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: AskScreen(controller: controller),
        ),
      ),
    );
    final dropdown = find.byType(DropdownButtonFormField<int>);
    await tester.scrollUntilVisible(
      dropdown,
      220,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text(preset.name).last);
    await tester.pumpAndSettle();
    expect(controller.connectionPreset!.name, preset.name);
    expect(
      find.textContaining('Requested model: selected-model'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
