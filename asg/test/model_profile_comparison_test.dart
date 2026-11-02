// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_connection_preset.dart';
import 'package:asg/models/model_runtime_metrics.dart';
import 'package:asg/models/model_profile_notes.dart';
import 'package:asg/models/model_test_observation.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/views/model_profile_comparison.dart';
import 'package:asg/views/model_settings.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'model_connection_presets_test.dart' show PresetRecords;

ModelConnectionPreset preset(String name, {bool metrics = false}) =>
    ModelConnectionPreset(
      name: name,
      config: LocalModelConfig(model: '$name-model'),
      testObservation: ModelTestObservation(
        jsonFormat: metrics,
        observedAt: DateTime.utc(2026, 11, 2),
        firstTextMilliseconds: metrics ? 20 : 50,
        completedMilliseconds: metrics ? 200 : 100,
        responseModel: metrics ? '$name-model' : null,
        runtimeMetrics: metrics
            ? const ModelRuntimeMetrics(
                promptTokens: 30,
                completionTokens: 10,
                tokensPerSecond: 12.34,
                peakMemoryGb: 5.67,
              )
            : null,
      ),
    );

void main() {
  testWidgets('declarations stay distinct from historical tests and refresh', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    ModelConnectionPreset declared(String name, ModelProfileNotes? notes) =>
        ModelConnectionPreset(
          name: name,
          config: const LocalModelConfig(),
          profileNotes: notes,
          testObservation: preset('Test').testObservation,
        );
    Future<void> show(List<ModelConnectionPreset> profiles) =>
        tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: Scaffold(
                body: SingleChildScrollView(
                  child: ModelProfileComparison(presets: profiles),
                ),
              ),
            ),
          ),
        );
    await show([
      declared(
        'Full',
        const ModelProfileNotes(
          revision: 'rev-one',
          license: 'license-one',
          architecture: 'arch-one',
          quantization: '4-bit',
          backend: 'MLX',
          contextTokens: 8192,
        ),
      ),
      declared('Partial', const ModelProfileNotes(quantization: '8-bit')),
      declared('Empty', const ModelProfileNotes()),
      declared('Legacy', null),
    ]);
    await tester.tap(find.text('Compare saved preset observations'));
    await tester.pumpAndSettle();
    Finder card(String name) =>
        find.ancestor(of: find.text(name), matching: find.byType(Card));
    void within(String name, String value) => expect(
      find.descendant(of: card(name), matching: find.text(value)),
      findsOneWidget,
    );
    within('Full', 'Declared revision: rev-one');
    within('Full', 'Declared license: license-one');
    within('Full', 'Declared architecture: arch-one');
    within('Full', 'Declared quantization: 4-bit');
    within('Full', 'Declared backend: MLX');
    within('Full', 'Declared context tokens: 8192');
    within('Partial', 'Declared quantization: 8-bit');
    within('Partial', 'Declared context tokens: unavailable (not saved)');
    within('Partial', 'Declared revision: unavailable (not saved)');
    for (final name in ['Empty', 'Legacy']) {
      within(name, 'Profile declarations: unavailable (not saved).');
    }
    expect(
      find.textContaining('may have changed since the test'),
      findsNWidgets(4),
    );
    expect(find.textContaining('not measured capacity'), findsNWidgets(4));
    await tester.ensureVisible(find.text('Legacy'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await show([
      declared('Full', const ModelProfileNotes(revision: 'rev-two')),
    ]);
    await tester.pumpAndSettle();
    expect(find.text('Declared revision: rev-one'), findsNothing);
    within('Full', 'Declared revision: rev-two');
    within('Full', 'Declared quantization: unavailable (not saved)');
    expect(
      find.textContaining('Historical response model ID:'),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 1000.0]) {
    testWidgets('comparison preserves distinct observations at width $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
              body: SingleChildScrollView(
                child: ModelProfileComparison(
                  presets: [
                    preset('Text'),
                    preset('JSON', metrics: true),
                    const ModelConnectionPreset(
                      name: 'Untested',
                      config: LocalModelConfig(model: 'never-tested'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Compare saved preset observations'));
      await tester.pumpAndSettle();
      expect(find.text(ModelProfileComparison.guidance), findsOneWidget);
      final textCard = find.ancestor(
        of: find.text('Text'),
        matching: find.byType(Card),
      );
      final jsonCard = find.ancestor(
        of: find.text('JSON'),
        matching: find.byType(Card),
      );
      expect(
        find.descendant(
          of: textCard,
          matching: find.textContaining(
            'Client first text: 50 ms; completed response: 100 ms',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: textCard,
          matching: find.textContaining('generation speed: unavailable'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: jsonCard,
          matching: find.textContaining('generation speed: 12.34 tokens/s'),
        ),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: jsonCard,
          matching: find.textContaining('process peak memory: 5.67 GB'),
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Test: JSON sentinel object'), findsOneWidget);
      expect(find.textContaining('Test: nonblank text'), findsOneWidget);
      expect(
        find.text('Historical test: unavailable (not saved).'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.text('Untested'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('empty and updated observations render without stale cards', (
    tester,
  ) async {
    Future<void> show(List<ModelConnectionPreset> presets) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ModelProfileComparison(presets: presets),
          ),
        ),
      ),
    );
    await show([preset('Before', metrics: true)]);
    await tester.tap(find.text('Compare saved preset observations'));
    await tester.pumpAndSettle();
    expect(find.textContaining('generation speed: 12.34'), findsOneWidget);
    await show([preset('After')]);
    await tester.pumpAndSettle();
    expect(find.text('Before'), findsNothing);
    expect(find.text('After'), findsOneWidget);
    expect(find.textContaining('generation speed: 12.34'), findsNothing);
    await show([]);
    await tester.pumpAndSettle();
    expect(find.byType(Card), findsNothing);
    expect(find.textContaining('No saved presets.'), findsOneWidget);
  });

  testWidgets(
    'settings comparison reads saved data without applying settings',
    (tester) async {
      final records = PresetRecords();
      final store = ModelSettingsStore(records);
      await store.savePresets([
        preset('First'),
        preset('Second', metrics: true),
      ]);
      final before = Map.of(records.values);
      var requests = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelSettings(
              store: store,
              inspectInventory: (_) async {
                requests++;
                return 'unexpected';
              },
            ),
          ),
        ),
      );
      await tester.ensureVisible(
        find.text('Compare saved preset observations'),
      );
      await tester.tap(find.text('Compare saved preset observations'));
      await tester.pumpAndSettle();
      expect(find.text('First'), findsOneWidget);
      expect(find.text('Second'), findsOneWidget);
      expect(records.values, before);
      expect(requests, 0);
      expect(store.load().model, const LocalModelConfig().model);
      expect(tester.takeException(), isNull);
    },
  );
}
