// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_connection_preset.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/views/model_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ask_controller_test.dart' show AskRecords, AskProvider, tick;
import 'chat_diagnostics_test.dart' show project;

const preset = ModelConnectionPreset(
  name: 'Local coding',
  config: LocalModelConfig(model: 'selected', chatOutputTokens: 512),
);
const other = StudioProject(
  id: 'other',
  name: 'Other',
  description: '',
  type: 'Flutter',
  platforms: ['Web'],
  location: '',
);
Future<ChatController> open(
  AskRecords records, {
  StudioProject target = project,
  AskProvider Function(LocalModelConfig)? provider,
}) async {
  final c = ChatController(
    target,
    openStore: () async => ConversationStore(records),
    createProvider:
        provider ??
        (_) => AskProvider()
          ..stream.add('answer')
          ..stream.close(),
  );
  await c.load();
  return c;
}

void main() {
  test('project snapshot survives deletion/reopen; other projects and global default remain separate', () async {
    final r = AskRecords();
    final settings = ModelSettingsStore(r);
    await settings.savePresets([preset]);
    final configs = <LocalModelConfig>[];
    AskProvider reply(LocalModelConfig c) {
      configs.add(c);
      return AskProvider()
        ..stream.add('answer')
        ..stream.close();
    }

    var c = await open(r, provider: reply);
    await c.choosePreset(c.presets.single);
    await settings.savePresets([]);
    await settings.save(const LocalModelConfig(model: 'global-new'));
    c.dispose();
    c = await open(r, provider: reply);
    expect(c.connectionPreset!.config.model, 'selected');
    await c.send('chosen');
    expect(c.messages.last.modelRequest!.model, 'selected');
    expect(c.messages.last.modelRequest!.outputTokens, 512);
    final second = await open(r, target: other, provider: reply);
    await second.send('global');
    expect(second.connectionPreset, isNull);
    await c.choosePreset(null);
    await c.send('global now');
    expect(configs.map((c) => c.model), [
      'selected',
      'global-new',
      'global-new',
    ]);
    expect(settings.load().model, 'global-new');
    c.dispose();
    second.dispose();
  });
  test('failed write retains selection; busy excludes sends and disposal suppresses publication', () async {
    final r = AskRecords();
    await ModelSettingsStore(r).savePresets([preset]);
    final c = await open(r);
    r.failWrite = r.writes + 1;
    await c.choosePreset(c.presets.single);
    expect(c.connectionPreset, isNull);
    expect(c.error, contains('could not be saved'));
    r.failWrite = null;
    r.gate = Completer<void>();
    final saving = c.choosePreset(c.presets.single);
    expect(c.busy, isTrue);
    expect(c.connectionPreset, isNull);
    expect(await c.send('blocked'), isFalse);
    await c.choosePreset(null);
    c.dispose();
    r.gate!.complete();
    await saving;
    expect(c.connectionPreset, isNull);
    expect(
      ConversationStore(r).loadConnection(project.id)!.config.model,
      'selected',
    );
  });
  test('streaming and unsaved answer refuse switch; save retry keeps request metadata', () async {
    final r = AskRecords();
    await ModelSettingsStore(r).savePresets([preset]);
    final provider = AskProvider();
    var calls = 0;
    final c = await open(
      r,
      provider: (_) {
        calls++;
        return provider;
      },
    );
    await c.choosePreset(c.presets.single);
    final pending = c.send('question');
    await tick();
    await c.choosePreset(null);
    expect(c.connectionPreset, isNotNull);
    r.failWrite = r.writes + 1;
    provider.stream.add('answer');
    await provider.stream.close();
    await pending;
    expect(c.hasUnsavedResponse, isTrue);
    await c.choosePreset(null);
    expect(c.connectionPreset, isNotNull);
    r.failWrite = null;
    await c.retrySavingResponse();
    expect(calls, 1);
    expect(c.messages.last.modelRequest!.model, 'selected');
    c.dispose();
  });
  test('corruption refuses requests and overwrites; stale screen refuses silent rerouting', () async {
    final r = AskRecords();
    final store = ConversationStore(r);
    final key = '${ConversationStore.selectionPrefix}${project.id}';
    for (final raw in [
      '{broken',
      '{}',
      '{"version":1.0,"preset":null}',
      '{"version":1,"preset":{}}',
      '{"version":1,"preset":null,"extra":1}',
      ' ' * 8193,
    ]) {
      r.values[key] = raw;
      final c = await open(r);
      expect(c.ready, isTrue);
      expect(c.connectionError, isNotNull);
      expect(await c.send('blocked'), isFalse);
      await c.choosePreset(null);
      expect(r.values[key], raw);
      c.dispose();
    }
    r.values.remove(key);
    final c = await open(r);
    await store.saveConnection(project.id, preset, expected: null);
    expect(await c.send('stale'), isFalse);
    expect(c.error, contains('reopen'));
    await expectLater(
      store.saveConnection(project.id, null, expected: null),
      throwsStateError,
    );
    c.dispose();
  });
  test(
    'actual HTTP selected endpoint and payload agree with saved provenance',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final payload = Completer<Map<String, dynamic>>();
      server.listen((request) async {
        payload.complete(
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
      final r = AskRecords();
      await ModelSettingsStore(r).savePresets([
        ModelConnectionPreset(
          name: 'Loopback',
          config: LocalModelConfig(
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            model: 'http-selected',
            chatOutputTokens: 512,
          ),
        ),
      ]);
      final c = ChatController(
        project,
        openStore: () async => ConversationStore(r),
      );
      try {
        await c.load();
        await c.choosePreset(c.presets.single);
        await c.send('question');
        final sent = await payload.future.timeout(const Duration(seconds: 5));
        expect(sent['model'], 'http-selected');
        expect(sent['max_tokens'], 512);
        expect(c.messages.last.modelRequest!.model, sent['model']);
      } finally {
        c.dispose();
        await server.close(force: true);
        HttpOverrides.global = previous;
      }
    },
  );
  test(
    'native reopen isolates corrupt connection and preserves raw data',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final dir = await Directory.systemTemp.createTemp('asg-chat-selection-');
      final path = '${dir.path}/records.db';
      var db = await databaseFactoryIo.openDatabase(path);
      final key = '${ConversationStore.selectionPrefix}${project.id}';
      try {
        var records = await StudioDatabase.migrate(db, prefs);
        await ConversationStore(records)
            .saveConnection(project.id, preset, expected: null);
        await db.close();
        db = await databaseFactoryIo.openDatabase(path);
        records = await StudioDatabase.migrate(db, prefs);
        expect(
          ConversationStore(records).loadConnection(project.id)!.config.model,
          'selected',
        );
        await StoreRef<String, String>('records')
            .record(key)
            .put(db, '{broken');
        await db.close();
        db = await databaseFactoryIo.openDatabase(path);
        records = await StudioDatabase.migrate(db, prefs);
        expect(
          () => ConversationStore(records).loadConnection(project.id),
          throwsFormatException,
        );
        await expectLater(
          ConversationStore(records)
              .saveConnection(project.id, null, expected: null),
          throwsFormatException,
        );
        await ModelSettingsStore(records)
            .save(const LocalModelConfig(model: 'unrelated'));
        expect(ConversationStore(records).loadConnection(other.id), isNull);
        expect(
          await StoreRef<String, String>('records').record(key).get(db),
          '{broken',
        );
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
  testWidgets('320px 2x selector handles reselection and preset removal', (
    tester,
  ) async {
    final r = AskRecords();
    await ModelSettingsStore(r).savePresets([preset]);
    final c = await open(r);
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: ModelChat(project: project, controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(
      find.byKey(const ValueKey('projectChatConnectionSettings')),
    );
    await tester.tap(find.text('Project advisory-chat connection'));
    await tester.pumpAndSettle();
    final dropdown = find.byKey(const ValueKey('projectChatConnection'));
    for (var i = 0; i < 2; i++) {
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Local coding').last);
      await tester.pumpAndSettle();
      expect(c.connectionPreset, isNotNull);
    }
    await ModelSettingsStore(r).savePresets([]);
    c.refreshPresets();
    await tester.pumpAndSettle();
    expect(tester.widget<DropdownButton<int>>(dropdown).value, -2);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Global model settings').last);
    await tester.pumpAndSettle();
    expect(c.connectionPreset, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
