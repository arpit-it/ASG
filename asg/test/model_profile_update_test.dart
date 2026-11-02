// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/controllers/model_settings_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_connection_preset.dart';
import 'package:asg/models/model_profile_notes.dart';
import 'package:asg/models/model_test_observation.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/views/model_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'model_connection_presets_test.dart' show PresetRecords;
import 'model_settings_controller_test.dart' show Probe;

const config = LocalModelConfig(model: 'requested', chatOutputTokens: 512);
const originalNotes = ModelProfileNotes(revision: 'original');
const newNotes = ModelProfileNotes(revision: 'new', contextTokens: 8192);

void main() {
  late PresetRecords records;
  late ModelSettingsStore store;
  late ModelSettingsController controller;
  late ModelTestObservation observation;
  var providerCalls = 0;
  setUp(() async {
    providerCalls = 0;
    records = PresetRecords();
    store = ModelSettingsStore(records);
    observation = ModelTestObservation(
      jsonFormat: true,
      observedAt: DateTime.utc(2026, 11, 2),
      firstTextMilliseconds: 50,
      completedMilliseconds: 100,
    );
    await store.savePresets([
      ModelConnectionPreset(
        name: 'Selected',
        config: config,
        profileNotes: originalNotes,
        testObservation: observation,
      ),
      const ModelConnectionPreset(name: 'Other', config: LocalModelConfig()),
    ]);
    controller = ModelSettingsController(
      store,
      createProvider: (_) {
        providerCalls++;
        return Probe();
      },
    );
    controller.selectPreset('Selected');
  });
  tearDown(() {
    if (!controller.isDisposed) controller.dispose();
  });

  test(
    'notes-only edit and clear preserve connection, history and ordering',
    () async {
      final before = store.loadPresets().map((p) => p.toJson()).toList();
      final active = store.load();
      for (final notes in [newNotes, null, const ModelProfileNotes()]) {
        await controller.saveProfileNotes(config, notes);
        final reopened = ModelSettingsController(ModelSettingsStore(records));
        final selected = reopened.presets.first.toJson();
        final expected = {...before.first}..remove('profileNotes');
        if (notes != null && !notes.isEmpty) {
          expected['profileNotes'] = notes.toJson();
        }
        expect(selected, expected);
        expect(reopened.presets.last.toJson(), before.last);
        expect(store.load().baseUrl, active.baseUrl);
        expect(store.load().model, active.model);
        expect(store.load().chatOutputTokens, active.chatOutputTokens);
        expect(controller.selectedPreset, 'Selected');
        reopened.dispose();
      }
      expect(providerCalls, 0);
    },
  );

  test(
    'invalid notes and failed writes preserve data for save-only retry',
    () async {
      final before = records.values[ModelSettingsStore.presetsKey];
      await controller.saveProfileNotes(
        config,
        const ModelProfileNotes(contextTokens: -1),
      );
      expect(records.values[ModelSettingsStore.presetsKey], before);
      expect(controller.presetStatus, contains('Invalid preset'));
      records.fail = true;
      await controller.saveProfileNotes(config, newNotes);
      expect(records.values[ModelSettingsStore.presetsKey], before);
      expect(controller.presets.first.profileNotes!.revision, 'original');
      expect(controller.canSaveProfileNotes(config), isTrue);
      records.fail = false;
      await controller.saveProfileNotes(config, newNotes);
      expect(store.loadPresets().first.profileNotes!.revision, 'new');
      expect(
        store.loadPresets().first.testObservation!.toJson(),
        observation.toJson(),
      );
      expect(providerCalls, 0);
    },
  );

  test(
    'different URL, model, budget and missing selection cannot edit notes',
    () async {
      final before = records.values[ModelSettingsStore.presetsKey];
      for (final draft in [
        const LocalModelConfig(model: 'other', chatOutputTokens: 512),
        const LocalModelConfig(
          baseUrl: 'http://localhost:9999',
          model: 'requested',
          chatOutputTokens: 512,
        ),
        const LocalModelConfig(model: 'requested', chatOutputTokens: 1024),
      ]) {
        expect(controller.canSaveProfileNotes(draft), isFalse);
        await controller.saveProfileNotes(draft, newNotes);
      }
      controller.selectedPreset = null;
      await controller.saveProfileNotes(config, newNotes);
      expect(records.values[ModelSettingsStore.presetsKey], before);
      expect(providerCalls, 0);
    },
  );

  test(
    'stale and corrupt stores refuse writes without losing historical data',
    () async {
      await store.savePresets([
        const ModelConnectionPreset(name: 'External', config: config),
      ]);
      final external = records.values[ModelSettingsStore.presetsKey];
      await controller.saveProfileNotes(config, newNotes);
      expect(records.values[ModelSettingsStore.presetsKey], external);
      expect(controller.presets.first.profileNotes!.revision, 'original');
      records.values[ModelSettingsStore.presetsKey] = '{broken';
      await controller.saveProfileNotes(config, newNotes);
      expect(records.values[ModelSettingsStore.presetsKey], '{broken');
      final corrupt = ModelSettingsController(store);
      expect(corrupt.canSaveProfileNotes(config), isFalse);
      await corrupt.saveProfileNotes(config, newNotes);
      corrupt.dispose();
      expect(records.values[ModelSettingsStore.presetsKey], '{broken');
    },
  );

  test(
    'pending writes block switching and disposal suppresses activation',
    () async {
      records.held = Completer<void>();
      final pending = controller.saveProfileNotes(config, newNotes);
      expect(controller.busy, isTrue);
      expect(controller.canSaveProfileNotes(config), isFalse);
      await controller.saveProfileNotes(config, null);
      expect(controller.selectPreset('Other'), isNull);
      expect(controller.presets.first.profileNotes!.revision, 'original');
      controller.dispose();
      records.held!.complete();
      await pending;
      expect(controller.presets.first.profileNotes!.revision, 'original');
      expect(store.loadPresets().first.profileNotes!.revision, 'new');
      expect(controller.canSaveProfileNotes(config), isFalse);
      expect(providerCalls, 0);
    },
  );

  test(
    'testing refuses edits; completed pending observation survives notes save',
    () async {
      controller.dispose();
      final probe = Probe();
      controller = ModelSettingsController(store, createProvider: (_) => probe);
      controller.selectPreset('Selected');
      final pending = controller.test(config);
      expect(controller.canSaveProfileNotes(config), isFalse);
      await controller.saveProfileNotes(config, newNotes);
      expect(controller.presets.first.profileNotes!.revision, 'original');
      probe.output.add('test complete');
      await probe.output.close();
      await pending;
      expect(controller.canSaveTestObservation(config), isTrue);
      await controller.saveProfileNotes(config, newNotes);
      expect(controller.canSaveTestObservation(config), isTrue);
      await controller.saveTestObservation(config);
      expect(store.loadPresets().first.profileNotes!.revision, 'new');
    },
  );

  testWidgets('notes-only save and clear remain usable at 320px and 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    final save = find.widgetWithText(OutlinedButton, 'Save profile notes only');
    expect(tester.widget<OutlinedButton>(save).onPressed, isNull);
    final dropdown = find.byType(DropdownButton<String>);
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selected').last);
    await tester.pumpAndSettle();
    final expand = find.text('Unverified model profile notes');
    final tile = find.ancestor(of: expand, matching: find.byType(ListTile));
    await Scrollable.ensureVisible(tester.element(tile));
    await tester.pumpAndSettle();
    // The enlarged tile is taller than the remaining dialog viewport. Its
    // visible top remains a real tappable expansion target.
    await tester.tapAt(tester.getTopLeft(tile) + const Offset(20, 20));
    await tester.pumpAndSettle();
    final revision = find.byKey(const ValueKey('Model revision note'));
    for (final value in ['changed', '']) {
      await tester.ensureVisible(revision);
      await tester.enterText(revision, value);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      final preset = store.loadPresets().first;
      expect(preset.profileNotes?.revision, value.isEmpty ? null : value);
      expect(preset.testObservation!.toJson(), observation.toJson());
      expect(preset.config.model, 'requested');
    }
    expect(tester.takeException(), isNull);
  });
}
