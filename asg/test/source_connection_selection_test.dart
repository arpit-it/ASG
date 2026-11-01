// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:asg/controllers/source_review_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_connection_preset.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/source_edit_proposer.dart';
import 'package:asg/views/source_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approved_source_proposer_test.dart' show seed, originals, response;
import 'planning_conversation_test.dart' show project, tick;
import 'source_candidate_controller_test.dart' show AtomicRecords;
import 'source_edit_proposer_test.dart' show FakeProvider;

const preset = ModelConnectionPreset(
  name: 'Coding',
  config: LocalModelConfig(model: 'chosen', chatOutputTokens: 512),
);
SourceReviewController open(
  AtomicRecords r, {
  ApprovedSourceProposer? proposer,
  SourceSnapshotReader? read,
}) => SourceReviewController(
  project: project,
  generated: GeneratedProject(
    directory: '/saved',
    sdk: '',
    python: '',
    sources: {'lib/main.dart': 'hash'},
  ),
  records: r,
  proposer: proposer,
  readSnapshot: read ?? (_, _) async => originals,
);
void main() {
  test('snapshot survives deletion/corruption; reset/reopen global and immutable evidence', () async {
    final r = AtomicRecords();
    await seed(r);
    final settings = ModelSettingsStore(r);
    await settings.savePresets([preset]);
    final configs = <LocalModelConfig>[];
    var provider = FakeProvider();
    final c = open(
      r,
      proposer: ApprovedSourceProposer(
        r,
        proposer: SourceEditProposer(
          createProvider: (config) {
            configs.add(config);
            return provider;
          },
        ),
      ),
    );
    c.choosePreset(c.presets.single);
    final selected = c.connectionPreset;
    await settings.savePresets([]);
    c.refreshPresets();
    expect(c.connectionPreset, same(selected));
    r.values[ModelSettingsStore.presetsKey] = 'corrupt';
    c.refreshPresets();
    expect(c.presetError, contains('could not be loaded'));
    Future<void> request() async {
      final pending = c.request('Tanalyze', ['lib/main.dart']);
      await tick();
      provider.stream.add(response());
      await provider.stream.close();
      await pending;
    }

    await request();
    final evidence = c.proposal!;
    expect(evidence.modelRequest!.model, 'chosen');
    expect(evidence.modelRequest!.outputTokens, 4096);
    await settings.save(const LocalModelConfig(model: 'global-new'));
    c.choosePreset(null);
    provider = FakeProvider();
    await request();
    expect(configs.map((e) => e.model), ['chosen', 'global-new']);
    expect(evidence.modelRequest!.model, 'chosen');
    expect(r.values[ModelSettingsStore.presetsKey], 'corrupt');
    expect(settings.load().model, 'global-new');
    c.dispose();
    c.choosePreset(selected);
    expect(c.connectionPreset, isNull);
    final reopened = open(r);
    expect(reopened.connectionPreset, isNull);
    reopened.dispose();
  });
  for (final selected in [false, true]) {
    test(
      'capture before async read; busy/disposal guards selected=$selected',
      () async {
        final r = AtomicRecords();
        await seed(r);
        final settings = ModelSettingsStore(r);
        await settings.savePresets([preset]);
        await settings.save(const LocalModelConfig(model: 'initial'));
        final gate = Completer<Map<String, String>>();
        final provider = FakeProvider();
        final configs = <LocalModelConfig>[];
        final c = open(
          r,
          read: (_, _) => gate.future,
          proposer: ApprovedSourceProposer(
            r,
            proposer: SourceEditProposer(
              createProvider: (config) {
                configs.add(config);
                return provider;
              },
            ),
          ),
        );
        if (selected) c.choosePreset(c.presets.single);
        final before = c.connectionPreset;
        final pending = c.request('Tanalyze', ['lib/main.dart']);
        await settings.save(const LocalModelConfig(model: 'changed'));
        c.choosePreset(selected ? null : c.presets.single);
        c.refreshPresets();
        expect(c.canChooseConnection, false);
        expect(c.connectionPreset, same(before));
        gate.complete(originals);
        await tick();
        provider.stream.add(response());
        await provider.stream.close();
        await pending;
        expect(configs.single.model, selected ? 'chosen' : 'initial');
        expect(c.proposal!.modelRequest!.model, configs.single.model);
        c.dispose();
        c.choosePreset(null);
        expect(c.connectionPreset, same(before));
      },
    );
  }
  testWidgets('320px 2x selector reselection/removal/refresh/reset', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final r = AtomicRecords();
    await seed(r);
    final settings = ModelSettingsStore(r);
    await settings.savePresets([preset]);
    final c = open(r);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: SourceReviewScreen(controller: c),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final title = find.text('Source/repair request connection');
    await tester.scrollUntilVisible(
      title,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(title);
    await tester.pumpAndSettle();
    await tester.tap(title);
    await tester.pumpAndSettle();
    final dropdown = find.byKey(const ValueKey('sourceConnection'));
    Future<void> select(String label) async {
      await Scrollable.ensureVisible(tester.element(dropdown), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text(label).last);
      await tester.pumpAndSettle();
    }

    await select('Coding');
    await select('Coding');
    expect(c.connectionPreset!.config.model, 'chosen');
    await settings.savePresets([]);
    final refresh = find.text('Refresh source/repair connection presets');
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
  });
}
