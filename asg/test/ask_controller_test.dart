// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/ask_controller.dart';
import 'package:asg/models/ask_conversation.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/ask_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/record_storage.dart';
import 'package:flutter_test/flutter_test.dart';

class AskRecords implements RecordStorage {
  final values = <String, String>{};
  int writes = 0;
  int? failWrite;
  Completer<void>? gate;
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    await gate?.future;
    if (writes == failWrite) return false;
    values[key] = value;
    return true;
  }
}

class AskProvider implements ModelProvider {
  final stream = StreamController<String>();
  final prompts = <String>[];
  bool cancelled = false;
  bool failCancel = false;
  @override
  Stream<String> generate(String prompt) {
    prompts.add(prompt);
    return stream.stream;
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (failCancel) throw StateError('private cancel error');
  }
}

Future<void> tick() => Future<void>.delayed(Duration.zero);
void main() {
  late AskRecords records;
  late AskProvider provider;
  late AskController controller;
  setUp(() {
    records = AskRecords();
    provider = AskProvider();
    controller = AskController(
      AskStore(records),
      createProvider: (_) => provider,
    )..load();
  });
  tearDown(() {
    if (!controller.isDisposed) controller.dispose();
  });
  test('Ask snapshots each requested model before initial save and restores metadata', () async {
    final settings = ModelSettingsStore(records);
    await settings.save(
      const LocalModelConfig(model: 'first', chatOutputTokens: 512),
    );
    records.gate = Completer<void>();
    final first = controller.send('first question');
    records.values['studio.localModel.v1'] = jsonEncode({
      'baseUrl': 'http://127.0.0.1:8765/v1',
      'model': 'second',
      'chatOutputTokens': 1024,
    });
    records.gate!.complete();
    await tick();
    provider.stream.add('first answer');
    await provider.stream.close();
    await first;
    final reopened = AskController(
      AskStore(records),
      createProvider: (config) {
        expect(config.model, 'second');
        expect(config.chatOutputTokens, 1024);
        return AskProvider()
          ..stream.add('second answer')
          ..stream.close();
      },
    )..load();
    await reopened.send('second question');
    final saved = AskStore(records)
        .load()
        .single
        .messages
        .where((m) => m.role == 'assistant')
        .toList();
    expect(saved.map((m) => m.modelRequest!.model), ['first', 'second']);
    expect(saved.map((m) => m.modelRequest!.outputTokens), [512, 1024]);
    expect(provider.prompts.single, isNot(contains('modelRequest')));
    reopened.dispose();
  });
  test('corrupt Ask provenance refuses overwrite and preserves original data', () async {
    const raw =
        '{"version":1,"conversations":[{"id":"ask-1","messages":[{"role":"user","content":"q"},{"role":"assistant","content":"a","modelRequest":null}]}]}';
    records.values[AskStore.key] = raw;
    controller.load();
    expect(controller.ready, isFalse);
    expect(await controller.send('overwrite'), isFalse);
    expect(records.values[AskStore.key], raw);
    expect(provider.prompts, isEmpty);
  });
  test('zero-project stream saves before inference, follow-up and separate history', () async {
    records.values['studio.chat.v1.project'] = 'private project discussion';
    final first = controller.send('Explain futures');
    await tick();
    expect(records.writes, 1);
    expect(controller.messages.single.content, 'Explain futures');
    provider.stream.add('A future ');
    await tick();
    expect(controller.draft, 'A future ');
    provider.stream.add('completes once.');
    await provider.stream.close();
    expect(await first, isTrue);
    expect(controller.messages.last.content, 'A future completes once.');
    final p2 = AskProvider();
    final reopened = AskController(AskStore(records), createProvider: (_) => p2)
      ..load();
    expect(reopened.messages.length, 2);
    final follow = reopened.send('And errors?');
    await tick();
    expect(p2.prompts.single, contains('A future completes once.'));
    expect(p2.prompts.single, isNot(contains('private project discussion')));
    p2.stream.add('Use try/catch.');
    await p2.stream.close();
    await follow;
    reopened.select(null);
    expect(reopened.messages, isEmpty);
    reopened.select(reopened.history.single.id);
    expect(reopened.messages.length, 4);
    expect(
      records.values['studio.chat.v1.project'],
      'private project discussion',
    );
    reopened.dispose();
  });
  test(
    'empty, oversized and full context refuse without writes or model',
    () async {
      expect(await controller.send('  '), isFalse);
      expect(
        await controller.send('x' * (AskController.inputLimit + 1)),
        isFalse,
      );
      expect(records.writes, 0);
      final saved = AskConversation(
        id: 'ask-1',
        messages: [
          const ChatMessage(role: 'user', content: 'Initial'),
          ChatMessage(role: 'assistant', content: 'a' * 23900),
        ],
      );
      records.values[AskStore.key] = AskStore.encode([saved]);
      controller.load();
      expect(await controller.send('follow up'), isFalse);
      expect(controller.error, contains('no context was silently dropped'));
      expect(records.writes, 0);
      expect(provider.prompts, isEmpty);
    },
  );
  test(
    'initial save failure retains unsent input and starts no inference',
    () async {
      records.failWrite = 1;
      expect(await controller.send('question'), isFalse);
      expect(controller.messages, isEmpty);
      expect(provider.prompts, isEmpty);
      expect(controller.error, contains('could not be saved or prepared'));
    },
  );
  test('final save failure retries without inference and blocks switching/new send', () async {
    records.failWrite = 2;
    final send = controller.send('question');
    await tick();
    provider.stream.add('completed answer');
    await provider.stream.close();
    await send;
    expect(controller.unsavedAnswer, 'completed answer');
    final captured = controller.unsavedReply!.modelRequest!;
    expect(captured.model, isNotEmpty);
    records.values['studio.localModel.v1'] = '{broken';
    expect(controller.messages.length, 1);
    controller.select(null);
    expect(controller.selectedId, 'ask-1');
    expect(await controller.send('duplicate'), isFalse);
    records.failWrite = null;
    await controller.retrySaving();
    expect(controller.unsavedAnswer, isNull);
    expect(controller.messages.length, 2);
    expect(provider.prompts.length, 1);
    expect(controller.messages.last.modelRequest!.toJson(), captured.toJson());
    expect(
      AskStore(records).load().single.messages.last.content,
      'completed answer',
    );
  });
  test(
    'offline errors sanitize details; retry uses saved question once',
    () async {
      final send = controller.send('question');
      await tick();
      provider.stream.addError(StateError('sensitive prompt http://private'));
      await send;
      expect(controller.error, isNot(contains('sensitive')));
      expect(controller.messages.length, 1);
      expect(controller.canRetryAnswer, isTrue);
      // A second independent screen/provider demonstrates reopen retry.
      final p2 = AskProvider();
      final reopened = AskController(
        AskStore(records),
        createProvider: (_) => p2,
      )..load();
      final retry = reopened.retryAnswer();
      await tick();
      p2.stream.add('Recovered');
      await p2.stream.close();
      await retry;
      expect(reopened.messages.length, 2);
      expect(reopened.messages.where((m) => m.role == 'user').length, 1);
      reopened.dispose();
    },
  );
  test('Stop immediately ends stalled stream, discards partial and permits new context', () async {
    provider.failCancel = true;
    final send = controller.send('question');
    await tick();
    provider.stream.add('partial');
    await tick();
    controller.stop();
    await send;
    expect(provider.cancelled, isTrue);
    expect(controller.busy, isFalse);
    expect(controller.draft, isEmpty);
    expect(controller.messages.length, 1);
    provider.stream.add('late');
    await tick();
    expect(controller.unsavedAnswer, isNull);
    controller.select(null);
    expect(controller.messages, isEmpty);
    await provider.stream.close();
  });
  test(
    'absolute deadline ends stalled stream and preserves saved question',
    () async {
      final timed = AskController(
        AskStore(records),
        createProvider: (_) => provider,
        requestLimit: const Duration(milliseconds: 10),
      )..load();
      await timed.send('timeout question');
      expect(timed.error, contains('timed out'));
      expect(provider.cancelled, isTrue);
      expect(timed.messages.length, 1);
      timed.dispose();
    },
  );
  test(
    'dispose pending save never starts provider or emits notifications',
    () async {
      records.gate = Completer<void>();
      final send = controller.send('question');
      controller.dispose();
      records.gate!.complete();
      await send;
      expect(provider.prompts, isEmpty);
      expect(
        AskStore(records).load().single.messages.single.content,
        'question',
      );
    },
  );
  test(
    'dispose during stream discards late output and releases provider',
    () async {
      final send = controller.send('question');
      await tick();
      controller.dispose();
      await send;
      provider.stream.add('late');
      await provider.stream.close();
      expect(provider.cancelled, isTrue);
      expect(AskStore(records).load().single.messages.length, 1);
    },
  );
  test('corrupt history fails closed without overwrite; stale concurrent save refused', () async {
    records.values[AskStore.key] = '{broken';
    controller.load();
    expect(controller.ready, isFalse);
    expect(await controller.send('question'), isFalse);
    expect(records.values[AskStore.key], '{broken');
    records.values.remove(AskStore.key);
    controller.load();
    final other = AskController(
      AskStore(records),
      createProvider: (_) => provider,
    )..load();
    records.values[AskStore.key] = AskStore.encode([
      AskConversation(
        id: 'ask-1',
        messages: [const ChatMessage(role: 'user', content: 'other window')],
      ),
    ]);
    expect(await other.send('overwrite'), isFalse);
    expect(
      AskStore(records).load().single.messages.single.content,
      'other window',
    );
    other.dispose();
  });
  test('invalid model settings block before question save', () async {
    records.values['studio.localModel.v1'] = '{broken';
    expect(await controller.send('question'), isFalse);
    expect(records.writes, 0);
    expect(provider.prompts, isEmpty);
  });
  test(
    'oversized/empty model answer fails without publishing partial',
    () async {
      final send = controller.send('question');
      await tick();
      provider.stream.add('x' * (AskConversation.maxMessageLength + 1));
      await send;
      expect(controller.messages.length, 1);
      expect(controller.unsavedAnswer, isNull);
      expect(controller.error, isNotNull);
    },
  );
  test('Ask schema rejects project authority, duplicate identity and future versions', () {
    expect(
      () => AskStore.decode('{"version":2,"conversations":[]}'),
      throwsFormatException,
    );
    final c = AskConversation(
      id: 'ask-1',
      messages: [const ChatMessage(role: 'user', content: 'q')],
    );
    expect(
      () => AskStore.decode(AskStore.encode([c, c])),
      throwsFormatException,
    );
    expect(
      () => AskConversation(
        id: 'ask-1',
        messages: [
          const ChatMessage(
            role: 'assistant',
            content: 'q',
            planContext: 'authority',
          ),
        ],
      ),
      throwsFormatException,
    );
  });
}
