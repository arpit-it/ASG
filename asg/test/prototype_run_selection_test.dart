// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:asg/controllers/app_workspace_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_connection_preset.dart';
import 'package:asg/services/application_editor.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/views/project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'ask_controller_test.dart' show AskRecords, tick;
import 'application_loop_test.dart' show project, changed, ReplyProvider;
import 'application_model_provenance_test.dart'
    show PendingProvider, validReply;

const preset = ModelConnectionPreset(
  name: 'Coding',
  config: LocalModelConfig(model: 'chosen', chatOutputTokens: 512),
);
Future<AppWorkspaceController> open(
  AskRecords r, {
  ApplicationEditor? editor,
}) async {
  final c = AppWorkspaceController(
    project,
    openStore: () async => ApplicationStore(r),
    editor:
        editor ??
        ApplicationEditor(
          allowBuiltInEdits: false,
          createProvider: (_) => ReplyProvider(validReply),
        ),
  );
  await c.load();
  return c;
}

void main() {
  test('session snapshot survives deletion; reset/reopen use global and history preserves request', () async {
    final r = AskRecords();
    final settings = ModelSettingsStore(r);
    await settings.savePresets([preset]);
    final configs = <LocalModelConfig>[];
    final c = await open(
      r,
      editor: ApplicationEditor(
        allowBuiltInEdits: false,
        createProvider: (config) {
          configs.add(config);
          return ReplyProvider(validReply);
        },
      ),
    );
    c.choosePreset(c.presets.single);
    final selected = c.connectionPreset;
    await settings.savePresets([]);
    await settings.save(const LocalModelConfig(model: 'global-new'));
    c.refreshPresets();
    expect(c.connectionPreset, same(selected));
    expect(c.presets, isEmpty);
    expect(await c.apply('custom one'), true);
    expect(configs.single.model, 'chosen');
    expect(c.messages.last.modelRequest!.model, 'chosen');
    expect(c.messages.last.modelRequest!.outputTokens, 2048);
    c.choosePreset(null);
    expect(await c.apply('custom two'), true);
    expect(configs.last.model, 'global-new');
    expect(settings.load().model, 'global-new');
    c.dispose();
    final reopened = await open(r);
    expect(reopened.connectionPreset, isNull);
    expect(reopened.messages[1].modelRequest!.model, 'chosen');
    reopened.dispose();
  });
  test(
    'streaming and disposal refuse selection; settings changes do not reroute',
    () async {
      final r = AskRecords();
      final settings = ModelSettingsStore(r);
      await settings.savePresets([preset]);
      final provider = PendingProvider();
      final c = await open(
        r,
        editor: ApplicationEditor(
          allowBuiltInEdits: false,
          createProvider: (_) => provider,
        ),
      );
      c.choosePreset(c.presets.single);
      final selected = c.connectionPreset;
      final pending = c.apply('custom');
      await provider.started.future;
      c.choosePreset(null);
      c.refreshPresets();
      expect(c.connectionPreset, same(selected));
      expect(c.canChooseConnection, false);
      await settings.save(const LocalModelConfig(model: 'other-global'));
      provider.reply.complete(validReply);
      expect(await pending, true);
      expect(c.messages.last.modelRequest!.model, 'chosen');
      c.dispose();
      c.choosePreset(null);
      expect(c.connectionPreset, same(selected));
    },
  );
  test('pending and failed preview save exclude switching; failed generation retains selection', () async {
    final r = AskRecords();
    await ModelSettingsStore(r).savePresets([preset]);
    final c = await open(r);
    c.choosePreset(c.presets.single);
    final selected = c.connectionPreset;
    r.gate = Completer<void>();
    r.failWrite = r.writes + 1;
    final pending = c.recordRuntimeState(changed);
    await tick();
    c.choosePreset(null);
    expect(c.connectionPreset, same(selected));
    r.gate!.complete();
    await pending;
    expect(c.hasUnsavedInteractions, true);
    c.choosePreset(null);
    expect(c.connectionPreset, same(selected));
    r.gate = null;
    r.failWrite = null;
    expect(await c.saveInteractions(), true);
    r.failWrite = r.writes + 1;
    expect(await c.apply('custom'), false);
    expect(c.connectionPreset, same(selected));
    expect(c.messages, isEmpty);
    c.choosePreset(null);
    expect(c.connectionPreset, isNull);
    c.dispose();
  });
  test(
    'corrupt refresh preserves snapshot/data and usable global fallback',
    () async {
      final r = AskRecords();
      await ModelSettingsStore(r).savePresets([preset]);
      final c = await open(r);
      c.choosePreset(c.presets.single);
      r.values[ModelSettingsStore.presetsKey] = 'corrupt';
      c.refreshPresets();
      expect(c.presetError, contains('could not be loaded'));
      expect(await c.apply('custom'), true);
      expect(c.messages.last.modelRequest!.model, 'chosen');
      c.choosePreset(null);
      expect(await c.apply('global custom'), true);
      expect(c.messages.last.modelRequest!.model, 'Qwen3.5-9B');
      expect(r.values[ModelSettingsStore.presetsKey], 'corrupt');
      c.dispose();
    },
  );
  testWidgets(
    '320px enlarged selector reselection/removal/reset remains controlled',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final r = AskRecords();
      await ModelSettingsStore(r).savePresets([preset]);
      final c = await open(r);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: ProjectWorkspace(project: project, controller: c),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byKey(const ValueKey('prototypeConnectionSettings')),
        150,
        scrollable: find
            .descendant(
              of: find.byType(ListView).first,
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.ensureVisible(find.text('Prototype request connection'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Prototype request connection'));
      await tester.pumpAndSettle();
      final dropdown = find.byKey(const ValueKey('prototypeConnection'));
      Future<void> select(String label) async {
        await Scrollable.ensureVisible(
          tester.element(dropdown),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(find.text(label).last);
        await tester.pumpAndSettle();
      }

      await select('Coding');
      expect(c.connectionPreset!.config.model, 'chosen');
      await select('Coding');
      await ModelSettingsStore(r).savePresets([]);
      final refresh = find.text('Refresh prototype connection presets');
      await Scrollable.ensureVisible(tester.element(refresh), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(refresh);
      await tester.pumpAndSettle();
      expect(c.presets, isEmpty);
      expect(tester.widget<DropdownButton<int>>(dropdown).value, -2);
      await select('Global model settings');
      expect(c.connectionPreset, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
