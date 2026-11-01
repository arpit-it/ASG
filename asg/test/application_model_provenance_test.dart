// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/app_workspace_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/services/application_editor.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/views/project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'application_loop_test.dart' show project, changed, editor;

class PendingProvider implements ModelProvider {
  final started = Completer<void>();
  final reply = Completer<String>();
  @override
  Stream<String> generate(String prompt) async* {
    started.complete();
    yield await reply.future;
  }

  @override
  Future<void> cancel() async {}
}

String get validReply =>
    jsonEncode({'summary': 'Changed', 'app': changed.toJson()});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'Build captures request model and fixed editor ceiling, not chat budget',
    () async {
      final store = ApplicationStore.fromPreferences(
        await SharedPreferences.getInstance(),
      );
      final settings = ModelSettingsStore(store.records);
      await settings.save(
        const LocalModelConfig(model: 'model-a', chatOutputTokens: 512),
      );
      final provider = PendingProvider();
      final configs = <LocalModelConfig>[];
      final c = AppWorkspaceController(
        project,
        openStore: () async => store,
        editor: ApplicationEditor(
          allowBuiltInEdits: false,
          createProvider: (config) {
            configs.add(config);
            return provider;
          },
        ),
      );
      await c.load();
      final pending = c.apply('custom change');
      await provider.started.future;
      await settings.save(
        const LocalModelConfig(model: 'model-b', chatOutputTokens: 1024),
      );
      provider.reply.complete(validReply);
      expect(await pending, true);
      expect(configs.single.model, 'model-a');
      final saved = ApplicationStore(store.records).load(project);
      expect(saved.messages.first.modelRequest, isNull);
      expect(saved.messages.last.modelRequest!.model, 'model-a');
      expect(saved.messages.last.modelRequest!.outputTokens, 2048);
      expect(saved.revision, 2);
      c.dispose();
      final second = AppWorkspaceController(
        project,
        openStore: () async => store,
        editor: editor(validReply),
      );
      await second.load();
      expect(await second.apply('another custom change'), true);
      expect(second.messages.last.modelRequest!.model, 'model-b');
      expect(second.messages[1].modelRequest!.model, 'model-a');
      second.dispose();
    },
  );

  test(
    'actual editor HTTP request matches recorded model and fixed ceiling',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
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
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': validReply},
                },
              ],
            })}\n\ndata: [DONE]\n\n',
          );
          await request.response.close();
        });
        final result = await ApplicationEditor(allowBuiltInEdits: false).apply(
          LocalModelConfig(
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            model: 'wire-model',
            chatOutputTokens: 512,
          ),
          changed,
          'custom change',
        );
        final body = await observed.future;
        expect(body['model'], result.modelRequest!.model);
        expect(body['max_tokens'], result.modelRequest!.outputTokens);
        expect(body['max_tokens'], 2048);
      } finally {
        await server.close(force: true);
        HttpOverrides.global = previous;
      }
    },
  );

  test(
    'built-in edits never create a provider or record a model request',
    () async {
      final store = ApplicationStore.fromPreferences(
        await SharedPreferences.getInstance(),
      );
      final c = AppWorkspaceController(
        project,
        openStore: () async => store,
        editor: ApplicationEditor(
          createProvider: (_) => throw StateError('No inference expected'),
        ),
      );
      await c.load();
      expect(await c.apply('change the theme to green'), true);
      expect(c.messages.last.modelRequest, isNull);
      expect(store.load(project).messages.last.modelRequest, isNull);
      c.dispose();
    },
  );

  for (final stop in ['cancel', 'dispose', 'malformed']) {
    test('$stop never publishes completed model provenance', () async {
      final store = ApplicationStore.fromPreferences(
        await SharedPreferences.getInstance(),
      );
      final provider = PendingProvider();
      final c = AppWorkspaceController(
        project,
        openStore: () async => store,
        editor: ApplicationEditor(
          allowBuiltInEdits: false,
          createProvider: (_) => provider,
        ),
      );
      await c.load();
      final pending = c.apply('custom change');
      await provider.started.future;
      if (stop == 'cancel') c.cancelGeneration();
      if (stop == 'dispose') c.dispose();
      provider.reply.complete(stop == 'malformed' ? 'invalid' : validReply);
      expect(await pending, false);
      expect(store.load(project).messages, isEmpty);
      expect(store.load(project).revision, 1);
      if (stop != 'dispose') c.dispose();
    });
  }

  test(
    'native reopen preserves Build provenance and corrupt metadata is retained',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'asg-build-provenance-',
      );
      final path = '${directory.path}/app.db';
      final preferences = await SharedPreferences.getInstance();
      var db = await databaseFactoryIo.openDatabase(path);
      try {
        var records = await StudioDatabase.migrate(db, preferences);
        final c = AppWorkspaceController(
          project,
          openStore: () async => ApplicationStore(records),
          editor: editor(validReply),
        );
        await c.load();
        expect(await c.apply('custom change'), true);
        c.dispose();
        await db.close();
        db = await databaseFactoryIo.openDatabase(path);
        records = await StudioDatabase.migrate(db, preferences);
        final loaded = ApplicationStore(records).load(project);
        expect(loaded.messages.last.modelRequest!.model, 'Qwen3.5-9B');
        expect(loaded.messages.last.modelRequest!.outputTokens, 2048);
        final key = 'studio.application.v1.${project.id}';
        final data =
            jsonDecode(records.getString(key)!) as Map<String, dynamic>;
        (data['messages'] as List).last['modelRequest']['outputTokens'] = -1;
        final corrupt = jsonEncode(data);
        await StoreRef<String, String>('records').record(key).put(db, corrupt);
        await db.close();
        db = await databaseFactoryIo.openDatabase(path);
        records = await StudioDatabase.migrate(db, preferences);
        expect(
          () => ApplicationStore(records).load(project),
          throwsFormatException,
        );
        expect(
          await StoreRef<String, String>('records').record(key).get(db),
          corrupt,
        );
      } finally {
        await db.close();
        await directory.delete(recursive: true);
      }
    },
  );

  for (final legacy in [false, true]) {
    testWidgets('narrow enlarged Build history shows metadata legacy=$legacy', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final store = ApplicationStore.fromPreferences(
        await SharedPreferences.getInstance(),
      );
      final c = AppWorkspaceController(
        project,
        openStore: () async => store,
        editor: editor(validReply),
      );
      final initial = store.load(project);
      await store.save(
        project.id,
        ApplicationSnapshot(initial.definition, const [
          ChatMessage(role: 'assistant', content: 'Legacy reply'),
        ], 1),
      );
      await c.load();
      if (!legacy) await c.apply('custom change');
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: ProjectWorkspace(project: project, controller: c),
          ),
        ),
      );
      await tester.pumpAndSettle();
      if (legacy) {
        expect(
          find.textContaining('Built-in actions use no model'),
          findsOneWidget,
        );
        expect(
          find.textContaining('Requested model: Qwen3.5-9B'),
          findsNothing,
        );
      } else {
        expect(
          find.textContaining('Requested model: Qwen3.5-9B'),
          findsOneWidget,
        );
        expect(
          find.textContaining(
            'Server-loaded weights and revision are unverified',
          ),
          findsOneWidget,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    });
  }
}
