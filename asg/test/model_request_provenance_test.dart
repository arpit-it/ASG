// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/views/model_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'chat_diagnostics_test.dart' show project;

class Records implements RecordStorage {
  final values = <String, String>{};
  bool failReply = false;
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    if (failReply &&
        key.startsWith('studio.chat.') &&
        value.contains('modelRequest')) {
      return false;
    }
    values[key] = value;
    return true;
  }
}

class Reply implements ModelProvider {
  final stream = StreamController<String>();
  @override
  Stream<String> generate(String prompt) => stream.stream;
  @override
  Future<void> cancel() async {
    if (!stream.isClosed) await stream.close();
  }
}

void main() {
  test('legacy JSON is unchanged; typed provenance round-trips and rejects corruption', () {
    final legacy = ChatMessage.fromJson({
      'role': 'assistant',
      'content': 'Old',
    });
    expect(legacy.modelRequest, isNull);
    expect(legacy.toJson(), {'role': 'assistant', 'content': 'Old'});
    expect(legacy.modelRequestDescription, contains('unavailable'));
    final metadata = ModelRequestProvenance.fromConfig(
      const LocalModelConfig(model: 'exact-model', chatOutputTokens: 512),
    );
    final message = ChatMessage(
      role: 'assistant',
      content: 'Reply',
      modelRequest: metadata,
    );
    expect(
      ChatMessage.fromJson(
        jsonDecode(jsonEncode(message.toJson())) as Map<String, dynamic>,
      ).modelRequest!.model,
      'exact-model',
    );
    for (final invalid in [
      null,
      {},
      {'version': 2, 'model': 'x', 'outputTokens': 512},
      {'version': 1, 'model': '', 'outputTokens': 512},
      {'version': 1, 'model': 'x', 'outputTokens': 512.0},
      {'version': 1, 'model': 'x', 'outputTokens': 0},
      {'version': 1, 'model': 'x', 'outputTokens': 512, 'extra': true},
    ]) {
      expect(
        () => ChatMessage.fromJson({
          'role': 'assistant',
          'content': 'Reply',
          'modelRequest': invalid,
        }),
        throwsFormatException,
      );
    }
    expect(
      () => ChatMessage.fromJson({
        'role': 'user',
        'content': 'Question',
        'modelRequest': metadata.toJson(),
      }),
      throwsFormatException,
    );
    expect(
      () => ChatMessage(
        role: 'user',
        content: 'Question',
        modelRequest: metadata,
      ).toJson(),
      throwsFormatException,
    );
    final archive = PortableProjectArchive(
      requirements: RequirementsBoard(),
      messages: [message],
    );
    expect(
      archive.messages.single.modelRequest,
      isNull,
      reason: 'Portable archives deliberately omit local request settings.',
    );
    expect(
      metadata.toJson().keys,
      unorderedEquals(['version', 'model', 'outputTokens']),
    );
  });
  for (final mode in [
    ConversationMode.discuss,
    ConversationMode.plan,
    ConversationMode.review,
  ]) {
    test(
      '${mode.name}: each completed reply retains the actual request snapshot across settings changes and reopen',
      () async {
        final records = Records();
        final settings = ModelSettingsStore(records);
        await settings.save(
          const LocalModelConfig(model: 'first', chatOutputTokens: 512),
        );
        final replies = <Reply>[];
        final configs = <LocalModelConfig>[];
        final controller = ChatController(
          project,
          openStore: () async => ConversationStore(records),
          createProvider: (config) {
            configs.add(config);
            final reply = Reply();
            replies.add(reply);
            return reply;
          },
        );
        await controller.load();
        controller.selectMode(mode);
        final first = controller.send('First question');
        while (replies.isEmpty) {
          await Future<void>.delayed(Duration.zero);
        }
        await settings.save(
          const LocalModelConfig(model: 'second', chatOutputTokens: 1024),
        );
        replies.first.stream.add('First response');
        await replies.first.stream.close();
        await first;
        final second = controller.send('Second question');
        while (replies.length < 2) {
          await Future<void>.delayed(Duration.zero);
        }
        replies.last.stream.add('Second response');
        await replies.last.stream.close();
        await second;
        expect(configs.map((c) => c.model), ['first', 'second']);
        final saved = ConversationStore(records)
            .load(project.id)
            .where((m) => m.role == 'assistant')
            .toList();
        expect(saved.map((m) => m.modelRequest!.model), ['first', 'second']);
        expect(saved.map((m) => m.modelRequest!.outputTokens), [512, 1024]);
        if (mode == ConversationMode.plan) {
          expect(saved.every((m) => m.planContext != null), isTrue);
        }
        controller.dispose();
      },
    );
  }
  test('failed final save retains original metadata and retry does not infer again', () async {
    final records = Records();
    final settings = ModelSettingsStore(records);
    await settings.save(
      const LocalModelConfig(model: 'original', chatOutputTokens: 512),
    );
    var calls = 0;
    final reply = Reply();
    final controller = ChatController(
      project,
      openStore: () async => ConversationStore(records),
      createProvider: (_) {
        calls++;
        return reply;
      },
    );
    await controller.load();
    records.failReply = true;
    final pending = controller.send('Question');
    while (calls == 0) {
      await Future<void>.delayed(Duration.zero);
    }
    reply.stream.add('Complete response');
    await reply.stream.close();
    await pending;
    expect(controller.hasUnsavedResponse, isTrue);
    expect(controller.unsavedResponse!.modelRequest!.model, 'original');
    expect(ConversationStore(records).load(project.id), hasLength(1));
    await settings.save(
      const LocalModelConfig(model: 'changed', chatOutputTokens: 2048),
    );
    records.failReply = false;
    await controller.retrySavingResponse();
    expect(calls, 1);
    expect(controller.hasUnsavedResponse, isFalse);
    expect(
      ConversationStore(records).load(project.id).last.modelRequest!.model,
      'original',
    );
    controller.dispose();
  });
  for (final stop in [true, false]) {
    test(
      'partial ${stop ? 'stopped' : 'failed'} reply never saves completed provenance',
      () async {
        final records = Records();
        final reply = Reply();
        var started = false;
        final controller = ChatController(
          project,
          openStore: () async => ConversationStore(records),
          createProvider: (_) {
            started = true;
            return reply;
          },
        );
        await controller.load();
        final pending = controller.send('Question');
        while (!started) {
          await Future<void>.delayed(Duration.zero);
        }
        reply.stream.add('Partial');
        if (stop) {
          controller.cancelGeneration();
        } else {
          reply.stream.addError(StateError('private failure'));
          await reply.stream.close();
        }
        await pending;
        expect(
          ConversationStore(records)
              .load(project.id)
              .every((m) => m.modelRequest == null),
          isTrue,
        );
        expect(controller.hasUnsavedResponse, isFalse);
        controller.dispose();
      },
    );
  }
  test('corrupt provenance preserves the stored conversation and refuses new requests', () async {
    final records = Records();
    final raw = jsonEncode([
      {'role': 'assistant', 'content': 'Saved', 'modelRequest': null},
    ]);
    records.values['studio.chat.v1.${project.id}'] = raw;
    final controller = ChatController(
      project,
      openStore: () async => ConversationStore(records),
      createProvider: (_) => throw StateError('must not connect'),
    );
    await controller.load();
    expect(controller.ready, isFalse);
    expect(await controller.send('Question'), isFalse);
    expect(records.values['studio.chat.v1.${project.id}'], raw);
    controller.dispose();
  });
  testWidgets(
    'narrow enlarged chat shows requested identity and explicit legacy unknown',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = Records();
      await ConversationStore(records).save(project.id, [
        const ChatMessage(
          role: 'assistant',
          content: 'New reply',
          modelRequest: ModelRequestProvenance(
            model: 'chosen-model',
            outputTokens: 512,
          ),
        ),
        const ChatMessage(role: 'assistant', content: 'Legacy reply'),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
            child: Scaffold(
              body: ModelChat(
                project: project,
                openStore: () async => ConversationStore(records),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Requested model: chosen-model'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Requested model unavailable'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
