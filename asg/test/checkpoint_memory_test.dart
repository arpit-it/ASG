// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/checkpoint_memory.dart';
import 'package:asg/models/model_catalog.dart';
import 'package:asg/models/runtime_capabilities.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/views/runtime_capability_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'runtime_capabilities_test.dart' as fixture;

RuntimeCapabilities capabilities({bool missing = false, bool? ready = true}) {
  final value = fixture.report(missing: missing);
  for (final item in value['backends']) {
    if (item['missing_dependencies'].isEmpty) item['device_ready'] = ready;
    if (ready == false) item['readiness'] = 'unavailable';
  }
  return RuntimeCapabilities.fromJson(value);
}

ModelCandidate model({
  int? bytes = 8 * gib,
  bool? quantized = true,
  bool supported = true,
}) => ModelCandidate(
  path: '/PRIVATE/model',
  name: 'PRIVATE',
  supported: supported,
  detail: 'PRIVATE token=secret',
  quantized: quantized,
  weightBytes: bytes,
);
ModelHardware memory({
  int? total = 32 * gib,
  int? available = 20 * gib,
  bool apple = true,
}) => ModelHardware(
  appleSilicon: apple,
  memoryBytes: total,
  availableBytes: available,
  detail: 'PRIVATE /secret',
);
CheckpointMemory assess({
  ModelCandidate? selected,
  ModelHardware? host,
  RuntimeCapabilities? report,
  RuntimeBackend backend = RuntimeBackend.mlx,
}) => CheckpointMemory.assess(
  capabilities: report ?? capabilities(),
  backend: backend,
  model: selected ?? model(),
  memory: host ?? memory(),
);

void main() {
  test(
    'estimate separates total boundary, headroom and unknown current memory',
    () {
      expect(assess().state, CheckpointMemoryState.estimated);
      expect(assess().workingBytes, 14 * gib);
      expect(
        assess(
          host: memory(total: 20 * gib, available: 14 * gib),
        ).state,
        CheckpointMemoryState.estimated,
      );
      expect(
        assess(
          host: memory(total: 20 * gib - 1, available: 14 * gib),
        ).state,
        CheckpointMemoryState.exceedsTotal,
      );
      expect(
        assess(host: memory(available: 14 * gib - 1)).state,
        CheckpointMemoryState.pressure,
      );
      expect(
        assess(host: memory(available: 0)).state,
        CheckpointMemoryState.pressure,
      );
      expect(
        assess(host: memory(available: null)).state,
        CheckpointMemoryState.unknown,
      );
      expect(assess(selected: model(bytes: 1)).workingBytes, 4 * gib + 2);
    },
  );
  test('legacy/incomplete/invalid inputs never yield estimated budget', () {
    for (final bytes in [null, 0, -1, 1125899906842624 + 1]) {
      expect(
        assess(selected: model(bytes: bytes)).state,
        CheckpointMemoryState.unknown,
      );
    }
    for (final candidate in [model(quantized: null), model(supported: false)]) {
      expect(assess(selected: candidate).workingBytes, isNull);
    }
    for (final host in [
      memory(total: null),
      memory(total: 0),
      memory(total: -1),
      memory(total: 1125899906842624 + 1),
      memory(available: -1),
      memory(available: 33 * gib),
      memory(apple: false),
    ]) {
      expect(assess(host: host).state, CheckpointMemoryState.unknown);
    }
    expect(
      CheckpointMemory.assess(
        capabilities: null,
        backend: RuntimeBackend.auto,
        model: model(),
        memory: memory(),
      ).state,
      CheckpointMemoryState.unknown,
    );
  });
  test(
    'backend availability, Auto preference and format remain independent gates',
    () {
      expect(
        assess(report: capabilities(ready: null)).state,
        CheckpointMemoryState.unknown,
      );
      expect(
        assess(report: capabilities(ready: false)).state,
        CheckpointMemoryState.unavailable,
      );
      expect(
        assess(report: capabilities(missing: true)).state,
        CheckpointMemoryState.unavailable,
      );
      expect(
        assess(
          report: capabilities(missing: true),
          backend: RuntimeBackend.auto,
        ).state,
        CheckpointMemoryState.unavailable,
      ); // Auto selects Torch; quantized weights rejected.
      expect(
        assess(
          report: capabilities(missing: true),
          backend: RuntimeBackend.auto,
          selected: model(quantized: false),
        ).state,
        CheckpointMemoryState.estimated,
      );
      expect(
        assess(backend: RuntimeBackend.torch).state,
        CheckpointMemoryState.unavailable,
      );
      final value = fixture.report();
      value['host']['system'] = 'Linux';
      expect(
        assess(report: RuntimeCapabilities.fromJson(value)).state,
        CheckpointMemoryState.unknown,
      );
    },
  );
  testWidgets(
    'narrow enlarged panel updates selection and clears stale estimates privately',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> show(
        ModelCandidate? selected, {
        bool inspected = true,
      }) async {
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: MediaQuery(
                data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
                child: SingleChildScrollView(
                  child: RuntimeCapabilityPanel(
                    report: inspected ? capabilities() : null,
                    selected: selected,
                    backend: RuntimeBackend.mlx,
                    memory: memory(),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('PRIVATE'), findsNothing);
      }

      await show(model());
      expect(find.textContaining('Within estimated RAM'), findsOneWidget);
      final detail = find.textContaining('Heuristic:');
      await tester.ensureVisible(detail);
      await tester.pumpAndSettle();
      expect(detail.hitTestable(), findsOneWidget);
      await show(model(bytes: 28 * gib));
      expect(find.textContaining('Exceeds estimated total'), findsOneWidget);
      expect(find.textContaining('Within estimated RAM'), findsNothing);
      await show(null);
      expect(find.textContaining('Scan and select a complete'), findsOneWidget);
      await show(model(), inspected: false);
      expect(find.text('Selected checkpoint memory estimate'), findsNothing);
      expect(find.textContaining('Estimated working memory:'), findsNothing);
    },
  );
}
