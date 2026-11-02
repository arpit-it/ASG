// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/model_settings_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_connection_preset.dart';
import 'package:asg/models/model_test_observation.dart';
import 'package:asg/models/model_profile_notes.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/views/model_test_observation_view.dart';
import 'package:asg/views/model_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'model_connection_presets_test.dart' show PresetRecords;
import 'model_settings_controller_test.dart' show Probe;

const config = LocalModelConfig(model: 'requested', chatOutputTokens: 512);
final observedAt = DateTime.utc(2026, 11, 2, 10);
ModelTestObservation observation({bool json = false}) => ModelTestObservation(
  jsonFormat: json,
  observedAt: observedAt,
  firstTextMilliseconds: 50,
  completedMilliseconds: 100,
);

void main() {
  late PresetRecords records;
  late ModelSettingsStore store;
  late ModelSettingsController controller;
  late Probe probe;
  late Duration elapsed;
  setUp(() async {
    records = PresetRecords();
    store = ModelSettingsStore(records);
    probe = Probe();
    elapsed = Duration.zero;
    controller = ModelSettingsController(
      store,
      createProvider: (_) => probe,
      elapsed: () => elapsed,
      now: () => observedAt,
    );
    await controller.savePreset('Selected', config);
    controller.selectPreset('Selected');
  });
  tearDown(() {
    if (!controller.isDisposed) controller.dispose();
  });
  Future<void> complete({bool json = false}) async {
    final pending = controller.test(config, jsonFormat: json);
    elapsed += const Duration(milliseconds: 50);
    probe.output.add(json ? '{"asg_probe":"ok"}' : 'private answer');
    await Future<void>.delayed(Duration.zero);
    elapsed += const Duration(milliseconds: 50);
    await probe.output.close();
    await pending;
  }

  for (final json in [false, true]) {
    test(
      'explicit ${json ? 'JSON' : 'text'} save retains metadata only',
      () async {
        final original = records.values[ModelSettingsStore.presetsKey];
        await complete(json: json);
        expect(records.values[ModelSettingsStore.presetsKey], original);
        expect(controller.canSaveTestObservation(config), isTrue);
        await controller.saveTestObservation(config);
        final reopened = ModelSettingsStore(records).loadPresets().single;
        expect(
          reopened.testObservation!.toJson(),
          observation(json: json).toJson(),
        );
        expect(reopened.config.model, 'requested');
        expect(store.load().model, const LocalModelConfig().model);
        final raw = records.values[ModelSettingsStore.presetsKey]!;
        for (final private in ['private answer', 'asg_probe', 'prompt']) {
          expect(raw, isNot(contains(private)));
        }
      },
    );
  }
  test(
    'remove only history preserves notes, other presets and active settings',
    () async {
      const notes = ModelProfileNotes(revision: 'pinned', contextTokens: 4096);
      await controller.savePreset(
        'Selected',
        config,
        replace: true,
        profileNotes: notes,
      );
      await controller.savePreset(
        'Other',
        const LocalModelConfig(model: 'other'),
      );
      controller.selectPreset('Selected');
      await complete();
      await controller.saveTestObservation(config);
      final active = (
        store.load().baseUrl,
        store.load().model,
        store.load().chatOutputTokens,
      );
      final other = controller.presets.last.toJson();
      expect(controller.canRemoveTestObservation, isTrue);
      await controller.removeTestObservation();
      final reopened = ModelSettingsController(ModelSettingsStore(records));
      addTearDown(reopened.dispose);
      final selected = reopened.presets.first;
      expect(selected.testObservation, isNull);
      expect(
        (
          selected.config.baseUrl,
          selected.config.model,
          selected.config.chatOutputTokens,
        ),
        (config.baseUrl, config.model, config.chatOutputTokens),
      );
      expect(selected.profileNotes!.toJson(), notes.toJson());
      expect(reopened.presets.last.toJson(), other);
      expect((
        store.load().baseUrl,
        store.load().model,
        store.load().chatOutputTokens,
      ), active);
      expect(controller.selectedPreset, 'Selected');
      expect(controller.canRemoveTestObservation, isFalse);
      expect(controller.canSaveTestObservation(config), isFalse);
      await controller.saveTestObservation(config);
      expect(store.loadPresets().first.testObservation, isNull);
      expect(probe.cancelled, isTrue);
    },
  );
  test(
    'remove failure retains history and pending result for save-only retry',
    () async {
      await complete();
      await controller.saveTestObservation(config);
      final original = records.values[ModelSettingsStore.presetsKey];
      records.fail = true;
      await controller.removeTestObservation();
      expect(records.values[ModelSettingsStore.presetsKey], original);
      expect(controller.presets.single.testObservation, isNotNull);
      expect(controller.canRemoveTestObservation, isTrue);
      expect(controller.canSaveTestObservation(config), isTrue);
      records.fail = false;
      await controller.removeTestObservation();
      expect(store.loadPresets().single.testObservation, isNull);
      expect(controller.canSaveTestObservation(config), isFalse);
    },
  );
  test(
    'remove refuses stale or corrupt storage without overwriting it',
    () async {
      await complete();
      await controller.saveTestObservation(config);
      await store.savePresets([
        const ModelConnectionPreset(name: 'External', config: config),
      ]);
      final external = records.values[ModelSettingsStore.presetsKey];
      await controller.removeTestObservation();
      expect(records.values[ModelSettingsStore.presetsKey], external);
      expect(controller.presets.single.testObservation, isNotNull);
      records.values[ModelSettingsStore.presetsKey] = '{broken';
      await controller.removeTestObservation();
      expect(records.values[ModelSettingsStore.presetsKey], '{broken');
      final reopened = ModelSettingsController(store);
      addTearDown(reopened.dispose);
      expect(reopened.canRemoveTestObservation, isFalse);
    },
  );
  test(
    'remove gates busy writes, tests, missing selection and disposal',
    () async {
      await complete();
      await controller.saveTestObservation(config);
      records.held = Completer<void>();
      final pending = controller.removeTestObservation();
      expect(controller.busy, isTrue);
      expect(controller.canRemoveTestObservation, isFalse);
      await controller.removeTestObservation();
      expect(controller.selectPreset('Selected'), isNull);
      expect(controller.presets.single.testObservation, isNotNull);
      controller.dispose();
      records.held!.complete();
      await pending;
      expect(controller.presets.single.testObservation, isNotNull);
      expect(store.loadPresets().single.testObservation, isNull);
      expect(controller.canRemoveTestObservation, isFalse);
    },
  );
  test(
    'active inference and selection without history refuse removal',
    () async {
      expect(controller.canRemoveTestObservation, isFalse);
      await controller.removeTestObservation();
      await complete();
      await controller.saveTestObservation(config);
      controller.selectedPreset = null;
      expect(controller.canRemoveTestObservation, isFalse);
      controller.selectedPreset = 'Selected';
      probe = Probe();
      final pending = controller.test(config);
      final original = records.values[ModelSettingsStore.presetsKey];
      await controller.removeTestObservation();
      expect(records.values[ModelSettingsStore.presetsKey], original);
      controller.stopTest();
      await pending;
      await controller.removeTestObservation();
      expect(store.loadPresets().single.testObservation, isNull);
    },
  );
  test('failed save retains pending observation for save-only retry', () async {
    await complete();
    final original = records.values[ModelSettingsStore.presetsKey];
    records.fail = true;
    await controller.saveTestObservation(config);
    expect(controller.presetStatus, contains('could not be saved'));
    expect(controller.presets.single.testObservation, isNull);
    expect(records.values[ModelSettingsStore.presetsKey], original);
    expect(controller.canSaveTestObservation(config), isTrue);
    records.fail = false;
    await controller.saveTestObservation(config);
    expect(store.loadPresets().single.testObservation, isNotNull);
  });
  test(
    'exact draft/preset matching, edits and restores gate attachment',
    () async {
      await complete();
      for (final different in [
        const LocalModelConfig(model: 'different', chatOutputTokens: 512),
        const LocalModelConfig(
          baseUrl: 'http://localhost:9999',
          model: 'requested',
          chatOutputTokens: 512,
        ),
        const LocalModelConfig(model: 'requested', chatOutputTokens: 1024),
      ]) {
        expect(controller.canSaveTestObservation(different), isFalse);
        await controller.saveTestObservation(different);
      }
      expect(store.loadPresets().single.testObservation, isNull);
      controller.connectionDraftChanged();
      expect(controller.canSaveTestObservation(config), isFalse);
      probe = Probe();
      await complete();
      controller.selectPreset('Selected');
      expect(controller.canSaveTestObservation(config), isFalse);
      await controller.savePreset('Other', const LocalModelConfig());
      controller.selectPreset('Other');
      probe = Probe();
      await complete();
      expect(controller.canSaveTestObservation(config), isFalse);
    },
  );
  test(
    'failed, empty, malformed JSON and stopped tests cannot save old success',
    () async {
      await complete();
      for (final failure in ['empty', 'json', 'error', 'stop']) {
        probe = Probe();
        final pending = controller.test(config, jsonFormat: failure == 'json');
        expect(controller.canSaveTestObservation(config), isFalse);
        if (failure == 'stop') {
          controller.stopTest();
        } else if (failure == 'error') {
          probe.output.addError(StateError('private diagnostics'));
        } else {
          probe.output.add(failure == 'json' ? '{"wrong":true}' : '  ');
        }
        await probe.output.close();
        await pending;
        expect(controller.canSaveTestObservation(config), isFalse);
        await controller.saveTestObservation(config);
      }
      expect(store.loadPresets().single.testObservation, isNull);
    },
  );
  test(
    'busy save blocks changes and publishes only after durable write',
    () async {
      await complete();
      records.held = Completer<void>();
      final pending = controller.saveTestObservation(config);
      expect(controller.busy, isTrue);
      expect(controller.presets.single.testObservation, isNull);
      expect(controller.canSaveTestObservation(config), isFalse);
      controller.connectionDraftChanged();
      expect(controller.selectPreset('Selected'), isNull);
      await controller.removePreset();
      records.held!.complete();
      await pending;
      expect(controller.presets.single.testObservation, isNotNull);
    },
  );
  test(
    'concurrent preset updates and corruption preserved without overwrite',
    () async {
      await complete();
      await store.savePresets([
        const ModelConnectionPreset(name: 'External', config: config),
      ]);
      final external = records.values[ModelSettingsStore.presetsKey];
      await controller.saveTestObservation(config);
      expect(records.values[ModelSettingsStore.presetsKey], external);
      records.values[ModelSettingsStore.presetsKey] = '{broken';
      await controller.saveTestObservation(config);
      expect(records.values[ModelSettingsStore.presetsKey], '{broken');
      expect(controller.presets.single.testObservation, isNull);
      final reopened = ModelSettingsController(store);
      expect(reopened.presetsLoadFailed, isTrue);
      expect(reopened.canSaveTestObservation(config), isFalse);
      reopened.dispose();
    },
  );
  test(
    'replacement clears historical observation and removal deletes it',
    () async {
      await complete();
      await controller.saveTestObservation(config);
      await controller.savePreset('Selected', config, replace: true);
      expect(store.loadPresets().single.testObservation, isNull);
      await controller.saveTestObservation(config);
      expect(store.loadPresets().single.testObservation, isNotNull);
      await controller.removePreset();
      expect(store.loadPresets(), isEmpty);
    },
  );
  test('disposal suppresses activation after pending write', () async {
    await complete();
    records.held = Completer<void>();
    final pending = controller.saveTestObservation(config);
    controller.dispose();
    records.held!.complete();
    await pending;
    expect(controller.presets.single.testObservation, isNull);
    expect(controller.canSaveTestObservation(config), isFalse);
  });
  test(
    'strict additive schema preserves legacy and rejects malformed metadata',
    () {
      final legacy = const ModelConnectionPreset(
        name: 'Legacy',
        config: config,
      ).toJson();
      expect(ModelConnectionPreset.fromJson(legacy).testObservation, isNull);
      for (final bad in [
        null,
        {...observation().toJson(), 'kind': 'verified'},
        {...observation().toJson(), 'outputTokens': 512},
        {...observation().toJson(), 'completedMilliseconds': 49},
        {...observation().toJson(), 'firstTextMilliseconds': -1},
        {...observation().toJson(), 'completedMilliseconds': 30001},
        {...observation().toJson(), 'observedAt': '2026-11-02'},
        {
          ...observation().toJson(),
          'observedAt': '2026-11-02T10:00:00.000+00:00',
        },
        {...observation().toJson(), 'response': 'private'},
        {...observation().toJson(), 'firstTextMilliseconds': 50.0},
      ]) {
        expect(
          () => ModelSettingsStore.decodePresets(
            jsonEncode({
              'version': 1,
              'presets': [
                {...legacy, 'testObservation': bad},
              ],
            }),
          ),
          throwsFormatException,
        );
      }
    },
  );
  testWidgets('historical selected-preset view is honest at 320px 2x', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await complete(json: true);
      await controller.saveTestObservation(config);
    });
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
    final dropdown = find.byType(DropdownButton<String>);
    await tester.ensureVisible(dropdown);
    await tester.tap(dropdown);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Selected').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byType(ModelTestObservationView));
    await tester.pumpAndSettle();
    expect(find.text('Saved historical test · Selected'), findsOneWidget);
    expect(
      find.textContaining('Requested model ID: requested'),
      findsOneWidget,
    );
    expect(find.textContaining('expected JSON sentinel'), findsOneWidget);
    expect(find.text(ModelTestObservation.guidance), findsOneWidget);
    final button = tester.widget<OutlinedButton>(
      find.widgetWithText(
        OutlinedButton,
        'Save test observation to selected preset',
      ),
    );
    expect(button.onPressed, isNull);
    final remove = find.widgetWithText(
      OutlinedButton,
      'Remove saved test observation only',
    );
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    expect(find.text('Saved historical test · Selected'), findsNothing);
    expect(store.loadPresets().single.testObservation, isNull);
    expect(store.loadPresets().single.config.model, 'requested');
    expect(tester.widget<OutlinedButton>(remove).onPressed, isNull);
    expect(tester.takeException(), isNull);
  });
}
