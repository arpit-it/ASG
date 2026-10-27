import 'dart:convert';

import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/local_model.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/views/model_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_diagnostics_test.dart' show project;

void main() {
  late SharedPreferences prefs;
  late ModelSettingsStore settings;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    settings = ModelSettingsStore.fromPreferences(prefs);
  });

  test('legacy default and every supported chat ceiling round-trip', () async {
    await prefs.setString(
      'studio.localModel.v1',
      jsonEncode({'baseUrl': 'http://127.0.0.1:8765/v1', 'model': 'legacy'}),
    );
    expect(settings.load().chatOutputTokens, 1536);
    for (final value in LocalModelConfig.chatTokenOptions) {
      await settings.save(LocalModelConfig(chatOutputTokens: value));
      expect(
        ModelSettingsStore.fromPreferences(prefs).load().chatOutputTokens,
        value,
      );
    }
    final saved = prefs.getString('studio.localModel.v1');
    for (final value in [0, -1, 511, 4096]) {
      await expectLater(
        settings.save(LocalModelConfig(chatOutputTokens: value)),
        throwsFormatException,
      );
      expect(prefs.getString('studio.localModel.v1'), saved);
    }
  });

  test(
    'invalid durable limits are refused without replacing records',
    () async {
      for (final value in [null, '512', 512.0, true, 0, 4096]) {
        final raw = jsonEncode({
          'baseUrl': 'http://127.0.0.1:8765/v1',
          'model': 'local',
          'chatOutputTokens': value,
        });
        await prefs.setString('studio.localModel.v1', raw);
        expect(settings.load, throwsFormatException);
        expect(prefs.getString('studio.localModel.v1'), raw);
      }
    },
  );

  test(
    'chat reloads saved ceiling for each actual transport request',
    () async {
      await settings.save(const LocalModelConfig(chatOutputTokens: 512));
      final sent = <int>[];
      final controller = ChatController(
        project,
        openStore: () async => ConversationStore.fromPreferences(prefs),
        createProvider: (config) => LocalModelProvider(
          config,
          maxTokens: config.chatOutputTokens,
          client: MockClient((request) async {
            sent.add((jsonDecode(request.body) as Map)['max_tokens'] as int);
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'content': 'Completed'},
                  },
                ],
              }),
              200,
            );
          }),
        ),
      );
      await controller.load();
      expect(controller.requestLimits, contains('512 output tokens'));
      await controller.send('First');
      await settings.save(const LocalModelConfig(chatOutputTokens: 1024));
      await controller.send('Second');
      expect(sent, [512, 1024]);
      expect(controller.requestLimits, contains('1024 output tokens'));
      expect(controller.messages, hasLength(4));
      controller.dispose();
    },
  );

  testWidgets('selected chat limit saves and reopens in settings', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ModelSettings(store: settings)),
      ),
    );
    final dropdown = find.byType(DropdownButtonFormField<int>);
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('512').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(settings.load().chatOutputTokens, 512);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ModelSettings(store: settings)),
      ),
    );
    expect(find.text('512'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('corrupt saved token limit is visible and cannot be overwritten', (
    tester,
  ) async {
    const raw =
        '{"baseUrl":"http://127.0.0.1:8765/v1","model":"local","chatOutputTokens":0}';
    await prefs.setString('studio.localModel.v1', raw);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ModelSettings(store: settings)),
      ),
    );
    expect(find.textContaining('could not be loaded'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );
    expect(prefs.getString('studio.localModel.v1'), raw);
    expect(tester.takeException(), isNull);
  });
  test(
    'corrupt model settings retain history and safely refuse new model work',
    () async {
      final store = ConversationStore.fromPreferences(prefs);
      await store.save(project.id, [
        const ChatMessage(role: 'assistant', content: 'saved history'),
      ]);
      for (final raw in [
        '{"baseUrl":"http://127.0.0.1:8765/v1","model":"local","chatOutputTokens":0}',
        'private-sentinel-invalid-json',
      ]) {
        await prefs.setString('studio.localModel.v1', raw);
        var requests = 0;
        final controller = ChatController(
          project,
          openStore: () async => store,
          createProvider: (_) {
            requests++;
            throw StateError('must not start');
          },
        );
        await controller.load();
        expect(controller.ready, isTrue);
        expect(controller.messages.single.content, 'saved history');
        expect(
          controller.requestLimits,
          contains('settings could not be loaded'),
        );
        expect(await controller.send('new prompt'), isFalse);
        expect(requests, 0);
        expect(controller.error, contains('settings could not be loaded'));
        expect(controller.error, isNot(contains('private-sentinel')));
        expect(store.load(project.id).single.content, 'saved history');
        expect(prefs.getString('studio.localModel.v1'), raw);
        controller.dispose();
      }
    },
  );
}
