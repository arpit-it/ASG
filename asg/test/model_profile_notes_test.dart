// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/controllers/model_settings_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/ask_conversation.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/models/model_connection_preset.dart';
import 'package:asg/models/model_profile_notes.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/views/model_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'model_connection_presets_test.dart' show PresetRecords;

const notes = ModelProfileNotes(
  revision: 'pinned-revision',
  license: 'MPL-2.0',
  architecture: 'Qwen',
  quantization: '4-bit',
  backend: 'Declared MLX',
  contextTokens: 32768,
);
const preset = ModelConnectionPreset(
  name: 'Profile',
  config: LocalModelConfig(),
  profileNotes: notes,
);

void main() {
  test(
    'legacy presets retain exact old schema; notes survive preset snapshots',
    () {
      final legacy = const ModelConnectionPreset(
        name: 'Legacy',
        config: LocalModelConfig(),
      ).toJson();
      expect(legacy.length, 4);
      expect(ModelConnectionPreset.fromJson(legacy).profileNotes, isNull);
      final restored = ModelConnectionPreset.fromJson(
        jsonDecode(jsonEncode(preset.toJson())),
      );
      expect(restored.profileNotes!.toJson(), notes.toJson());
      expect(
        restored.config.chatOutputTokens,
        LocalModelConfig.defaultChatOutputTokens,
      );
      expect(restored.toJson().keys, isNot(contains('verified')));
    },
  );

  test(
    'Ask and project snapshots keep original notes after preset replacement',
    () async {
      final records = PresetRecords();
      final settings = ModelSettingsStore(records);
      await settings.savePresets([preset]);
      final conversations = ConversationStore(records);
      await conversations.saveConnection('project', preset, expected: null);
      final ask = AskConversation(
        id: 'ask-1',
        messages: [const ChatMessage(role: 'user', content: 'Question')],
        connectionPreset: preset,
      );
      final savedAsk = jsonEncode(ask.toJson());
      await settings.savePresets([
        const ModelConnectionPreset(
          name: 'Profile',
          config: LocalModelConfig(),
          profileNotes: ModelProfileNotes(revision: 'changed'),
        ),
      ]);
      expect(
        conversations.loadConnection('project')!.profileNotes!.revision,
        notes.revision,
      );
      expect(
        AskConversation.fromJson(jsonDecode(savedAsk) as Map<String, dynamic>)
            .connectionPreset!
            .profileNotes!
            .toJson(),
        notes.toJson(),
      );
      expect(settings.loadPresets().single.profileNotes!.revision, 'changed');
    },
  );

  test(
    'strict bounded declarations refuse malformed and claimed verified fields',
    () {
      final valid = notes.toJson();
      for (final invalid in [
        null,
        [],
        {},
        {...valid, 'verified': true},
        {...valid}..remove('contextTokens'),
        {...valid, 'contextTokens': 1.5},
        {...valid, 'contextTokens': true},
        {...valid, 'contextTokens': 0},
        {...valid, 'contextTokens': 1048577},
        {...valid, 'revision': ' private '},
        {...valid, 'license': 'x' * 257},
        {...valid, 'backend': 'bad\ntext'},
        {...valid, 'architecture': 3},
      ]) {
        expect(
          () => ModelConnectionPreset.fromJson({
            ...preset.toJson(),
            'profileNotes': invalid,
          }),
          throwsFormatException,
        );
      }
      for (final limit in [1, 1048576]) {
        expect(
          ModelProfileNotes.fromJson({...valid, 'contextTokens': limit})
              .contextTokens,
          limit,
        );
      }
      expect(
        ModelProfileNotes.fromJson({...valid, 'contextTokens': null})
            .contextTokens,
        isNull,
      );
    },
  );

  test('failed replacement retains notes, retry persists, stale screen refuses changes', () async {
    final records = PresetRecords();
    final store = ModelSettingsStore(records);
    await store.savePresets([preset]);
    final c = ModelSettingsController(store);
    c.selectPreset('Profile');
    records.fail = true;
    await c.savePreset(
      'Profile',
      const LocalModelConfig(model: 'new'),
      replace: true,
      profileNotes: const ModelProfileNotes(contextTokens: 2048),
    );
    expect(c.presets.single.profileNotes!.revision, notes.revision);
    expect(store.loadPresets().single.profileNotes!.revision, notes.revision);
    records.fail = false;
    await c.savePreset(
      'Profile',
      const LocalModelConfig(model: 'new'),
      replace: true,
      profileNotes: const ModelProfileNotes(contextTokens: 2048),
    );
    expect(store.loadPresets().single.profileNotes!.contextTokens, 2048);
    final stale = ModelSettingsController(store);
    stale.selectPreset('Profile');
    c.selectPreset('Profile');
    await c.savePreset(
      'Profile',
      const LocalModelConfig(),
      replace: true,
      profileNotes: notes,
    );
    await stale.removePreset();
    expect(stale.presetStatus, contains('could not be saved'));
    expect(store.loadPresets().single.profileNotes!.revision, notes.revision);
    c.dispose();
    stale.dispose();
  });

  test(
    'corrupt notes preserved and invalid write cannot replace old record',
    () async {
      final records = PresetRecords();
      final store = ModelSettingsStore(records);
      await store.savePresets([preset]);
      final original = records.values[ModelSettingsStore.presetsKey];
      await expectLater(
        store.savePresets([
          const ModelConnectionPreset(
            name: 'Invalid',
            config: LocalModelConfig(),
            profileNotes: ModelProfileNotes(contextTokens: -1),
          ),
        ]),
        throwsFormatException,
      );
      expect(records.values[ModelSettingsStore.presetsKey], original);
      final corrupt = jsonEncode({
        'version': 1,
        'presets': [
          {
            ...preset.toJson(),
            'profileNotes': {'verified': true},
          },
        ],
      });
      records.values[ModelSettingsStore.presetsKey] = corrupt;
      final c = ModelSettingsController(store);
      expect(c.presetsLoadFailed, isTrue);
      await c.savePreset('Other', const LocalModelConfig());
      expect(records.values[ModelSettingsStore.presetsKey], corrupt);
      c.dispose();
    },
  );

  testWidgets(
    'profile fields restore, legacy selection clears, explicit save retains notes at narrow enlarged layout',
    (tester) async {
      tester.view.physicalSize = const Size(640, 1500);
      tester.view.devicePixelRatio = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = PresetRecords();
      final store = ModelSettingsStore(records);
      await store.savePresets([
        preset,
        const ModelConnectionPreset(
          name: 'Legacy',
          config: LocalModelConfig(model: 'legacy'),
        ),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(body: ModelSettings(store: store)),
        ),
      );
      Future<void> select(String name) async {
        final dropdown = find.byType(DropdownButton<String>);
        await tester.ensureVisible(dropdown);
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text(name).last);
        await tester.pumpAndSettle();
      }

      await select('Profile');
      await tester.ensureVisible(find.text('Unverified model profile notes'));
      await tester.tap(find.text('Unverified model profile notes'));
      await tester.pumpAndSettle();
      String field(String label) => tester
          .widget<TextField>(find.byKey(ValueKey(label)))
          .controller!
          .text;
      expect(field('Model revision note'), notes.revision);
      expect(field('Declared context tokens'), '32768');
      expect(find.text(ModelProfileNotes.guidance), findsOneWidget);
      await select('Legacy');
      expect(field('Model revision note'), '');
      expect(field('Declared context tokens'), '');
      await tester.ensureVisible(
        find.byKey(const ValueKey('Model revision note')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('Model revision note')),
        'new-revision',
      );
      final replace = find.text('Replace selected');
      await tester.ensureVisible(replace);
      await tester.tap(replace);
      await tester.pumpAndSettle();
      expect(
        store
            .loadPresets()
            .firstWhere((p) => p.name == 'Legacy')
            .profileNotes!
            .revision,
        'new-revision',
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('Declared context tokens')),
      );
      await tester.enterText(
        find.byKey(const ValueKey('Declared context tokens')),
        'invalid',
      );
      await tester.ensureVisible(replace);
      await tester.tap(replace);
      await tester.pumpAndSettle();
      expect(
        store
            .loadPresets()
            .firstWhere((p) => p.name == 'Legacy')
            .profileNotes!
            .contextTokens,
        isNull,
      );
      expect(field('Declared context tokens'), 'invalid');
      expect(find.textContaining('Invalid preset.'), findsOneWidget);
      expect(store.load().model, 'Qwen3.8-27B-4bit');
      expect(tester.takeException(), isNull);
    },
  );
}
