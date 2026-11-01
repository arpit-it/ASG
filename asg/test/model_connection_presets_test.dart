// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/model_settings_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_connection_preset.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/views/model_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class PresetRecords implements RecordStorage {
  final values = <String, String>{};
  bool fail = false;
  Completer<void>? held;
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    await held?.future;
    if (fail) return false;
    values[key] = value;
    return true;
  }
}

const first = LocalModelConfig(model: 'first', chatOutputTokens: 512);
const second = LocalModelConfig(
  baseUrl: 'http://localhost:9876/v1',
  model: 'second',
  chatOutputTokens: 2048,
);

void main() {
  test(
    'create, explicit replace, remove, reopen leave active settings alone',
    () async {
      final records = PresetRecords();
      final store = ModelSettingsStore(records);
      await store.save(const LocalModelConfig(model: 'active'));
      final c = ModelSettingsController(store);
      await c.savePreset(' First ', first);
      await c.savePreset('Second', second);
      expect(c.presets.map((p) => p.name), ['First', 'Second']);
      await c.savePreset('First', second);
      expect(c.presets.first.config.model, 'first');
      expect(c.presetStatus, contains('already exists'));
      expect(c.selectPreset('First')?.model, 'first');
      await c.savePreset('First', second, replace: true);
      expect(c.selectPreset('First')?.chatOutputTokens, 2048);
      expect(store.load().model, 'active');
      final reopened = ModelSettingsController(ModelSettingsStore(records));
      expect(reopened.presets.length, 2);
      expect(reopened.selectPreset('First')?.baseUrl, second.baseUrl);
      await reopened.removePreset();
      expect(reopened.selectedPreset, isNull);
      expect(store.loadPresets().single.name, 'Second');
      expect(store.load().model, 'active');
      expect(() => c.presets.clear(), throwsUnsupportedError);
      reopened.dispose();
      c.dispose();
    },
  );

  test(
    'escaped bounded fields reject before writes and preserve the prior record',
    () async {
      final records = PresetRecords();
      final store = ModelSettingsStore(records);
      await store.savePresets([
        const ModelConnectionPreset(name: 'Original', config: first),
      ]);
      final original = records.values[ModelSettingsStore.presetsKey];
      final config = LocalModelConfig(
        baseUrl: 'http://localhost/${'\u0001' * 490}',
        model: '\u0001' * 256,
      );
      final oversized = List.generate(
        20,
        (i) => ModelConnectionPreset(name: 'Preset $i', config: config),
      );
      await expectLater(store.savePresets(oversized), throwsFormatException);
      expect(records.values[ModelSettingsStore.presetsKey], original);
      expect(store.loadPresets().single.name, 'Original');
    },
  );

  test(
    'invalid schema/config/duplicates/count preserve corrupt records',
    () async {
      final good = ModelConnectionPreset(name: 'One', config: first).toJson();
      for (final value in [
        '{}',
        'not json',
        jsonEncode({'version': 2, 'presets': []}),
        jsonEncode({'version': 1.0, 'presets': []}),
        jsonEncode({
          'version': 1,
          'presets': [good, good],
        }),
        jsonEncode({
          'version': 1,
          'presets': [
            {...good, 'baseUrl': 'https://remote.invalid'},
          ],
        }),
        jsonEncode({
          'version': 1,
          'presets': [
            {...good, 'chatOutputTokens': 4096},
          ],
        }),
        jsonEncode({
          'version': 1,
          'presets': [
            {...good, 'name': '  '},
          ],
        }),
        jsonEncode({
          'version': 1,
          'presets': [
            {...good, 'extra': true},
          ],
        }),
        jsonEncode({
          'version': 1,
          'presets': List.generate(21, (i) => {...good, 'name': '$i'}),
        }),
      ]) {
        final records = PresetRecords()
          ..values[ModelSettingsStore.presetsKey] = value;
        final store = ModelSettingsStore(records);
        final c = ModelSettingsController(store);
        expect(c.presetsLoadFailed, isTrue);
        await c.savePreset('New', first);
        await expectLater(store.savePresets([]), throwsFormatException);
        expect(records.values[ModelSettingsStore.presetsKey], value);
        await c.save(
          first,
        ); // Preset corruption does not block unrelated settings.
        expect(store.load().model, 'first');
        c.dispose();
      }
    },
  );

  test(
    'failed writes retain list; busy and disposed actions do not overlap',
    () async {
      final records = PresetRecords();
      final store = ModelSettingsStore(records);
      final c = ModelSettingsController(store);
      await c.savePreset('One', first);
      c.selectPreset('One');
      records.fail = true;
      await c.savePreset('One', second, replace: true);
      await c.removePreset();
      expect(c.presets.single.config.model, 'first');
      expect(c.selectedPreset, 'One');
      expect(c.presetStatus, contains('retained'));
      records.fail = false;
      records.held = Completer<void>();
      final pending = c.savePreset('Two', second);
      expect(c.busy, isTrue);
      expect(c.selectPreset('One'), isNull);
      await c.removePreset();
      await c.save(first);
      await c.test(first);
      expect(records.values['studio.localModel.v1'], isNull);
      c.dispose();
      records.held!.complete();
      await pending;
      expect(c.presets.length, 1); // No post-disposal state publication.
      await c.savePreset('Three', first);
      expect(store.loadPresets().map((p) => p.name), ['One', 'Two']);
    },
  );

  test(
    'invalid new names and local configurations preserve existing presets',
    () async {
      final records = PresetRecords();
      final c = ModelSettingsController(ModelSettingsStore(records));
      await c.savePreset('Original', first);
      for (final name in ['', 'x' * 65, 'bad\nname']) {
        await c.savePreset(name, second);
        expect(c.presets.length, 1);
      }
      await c.savePreset(
        'Invalid',
        const LocalModelConfig(baseUrl: 'http://secret@localhost/v1'),
      );
      expect(c.presets.length, 1);
      expect(c.presetStatus, isNot(contains('secret')));
      c.dispose();
    },
  );

  testWidgets(
    'restore updates all draft fields; only explicit Save applies them',
    (tester) async {
      final records = PresetRecords();
      final store = ModelSettingsStore(records);
      await store.save(first);
      await store.savePresets([
        const ModelConnectionPreset(name: 'Second', config: second),
      ]);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ModelSettings(store: store)),
        ),
      );
      final picker = find.byType(DropdownButton<String>);
      await tester.ensureVisible(picker);
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Second').last);
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<TextField>(find.byType(TextField))
            .map((w) => w.controller!.text),
        [second.baseUrl, second.model, 'Second'],
      );
      expect(find.text('2048'), findsOneWidget);
      expect(store.load().model, 'first');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(store.load().model, 'second');
      expect(store.load().chatOutputTokens, 2048);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [280.0, 360.0]) {
    testWidgets(
      'preset workflow remains tappable at $width with enlarged text',
      (tester) async {
        tester.view.physicalSize = Size(width, 640);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final records = PresetRecords();
        final store = ModelSettingsStore(records);
        await store.save(first);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(1.8)),
              child: child!,
            ),
            home: Scaffold(body: ModelSettings(store: store)),
          ),
        );
        final fields = tester
            .widgetList<TextField>(find.byType(TextField))
            .toList();
        fields[1].controller!.text = 'draft';
        fields[2].controller!.text = 'x' * 64;
        Future<void> tapVisible(Finder finder) async {
          await Scrollable.ensureVisible(
            tester.element(finder),
            alignment: 0.5,
          );
          await tester.pumpAndSettle();
          expect(finder.hitTestable(), findsOneWidget);
          await tester.tap(finder);
          await tester.pumpAndSettle();
        }

        await tapVisible(
          find.widgetWithText(OutlinedButton, 'Save new preset'),
        );
        expect(store.loadPresets().single.config.model, 'draft');
        await tapVisible(find.byType(DropdownButton<String>));
        await tester.tap(find.text('x' * 64).last);
        await tester.pumpAndSettle();
        fields[1].controller!.text = 'replacement';
        records.fail = true;
        final replace = find.widgetWithText(OutlinedButton, 'Replace selected');
        await tapVisible(replace);
        expect(store.loadPresets().single.config.model, 'draft');
        expect(fields[1].controller!.text, 'replacement');
        records.fail = false;
        await tapVisible(replace);
        expect(store.loadPresets().single.config.model, 'replacement');
        await tapVisible(find.widgetWithText(TextButton, 'Remove selected'));
        expect(store.loadPresets(), isEmpty);
        expect(store.load().model, 'first');
        expect(tester.takeException(), isNull);
      },
    );
  }
}
