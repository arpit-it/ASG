// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/controllers/runtime_setup_controller.dart';
import 'package:asg/models/model_catalog.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/models/runtime_capabilities.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/views/runtime_capability_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'runtime_capabilities_test.dart' as discovery;
import 'runtime_setup_test.dart' as fixture;

Future<RuntimeSetupController> controller(
  Future<ModelHardware> Function() inspect, {
  discovery.DiscoveryHost? host,
}) async {
  final prefs = await SharedPreferences.getInstance();
  return RuntimeSetupController(
    store: RuntimeSetupStore.fromPreferences(prefs),
    modelStore: ModelSettingsStore.fromPreferences(prefs),
    host: host ?? discovery.DiscoveryHost(),
    inspectMemory: inspect,
    connection: fixture.connection(ready: () => false),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('memory failure retains capabilities, retries and preserves runtime/settings', () async {
    var fail = true;
    final host = discovery.DiscoveryHost()..ownsProcess = true;
    final c = await controller(() async {
      if (fail) throw StateError('PRIVATE /secret');
      return const ModelHardware(
        appleSilicon: true,
        memoryBytes: 32 * gib,
        availableBytes: 0,
      );
    }, host: host);
    addTearDown(c.dispose);
    c.initialize();
    const saved = RuntimeSetup(
      python: '/previous',
      backend: RuntimeBackend.mlx,
    );
    await c.saveSetup(saved);
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('studio.runtimeSetup.v1');
    await c.discover('/python');
    expect(c.capabilities, isNotNull);
    expect(c.memory?.memoryBytes, isNull);
    expect(c.error, isNull);
    fail = false;
    await c.discover('/python');
    expect(c.memory?.memoryBytes, 32 * gib);
    expect(c.memory?.availableBytes, 0);
    expect(c.setup, same(saved));
    expect(prefs.getString('studio.runtimeSetup.v1'), raw);
    expect(host.stops, 0);
    expect(host.downloads, 0);
    expect(host.ownsProcess, isTrue);
    c.invalidateCapabilities();
    expect(c.memory, isNull);
  });
  test('late memory is excluded on invalidation/disposal and overlapping inspection', () async {
    for (final dispose in [false, true]) {
      final entered = Completer<void>();
      final gate = Completer<ModelHardware>();
      var calls = 0;
      final c = await controller(() {
        calls++;
        entered.complete();
        return gate.future;
      });
      final pending = c.discover('/python');
      await entered.future;
      await c.discover('/other');
      expect(calls, 1);
      expect(c.busy, isTrue);
      if (dispose) {
        c.dispose();
      } else {
        c.invalidateCapabilities();
      }
      gate.complete(
        const ModelHardware(appleSilicon: true, memoryBytes: 32 * gib),
      );
      await pending;
      expect(c.memory, isNull);
      expect(c.capabilities, isNull);
      if (!dispose) c.dispose();
    }
  });
  testWidgets('320px enlarged memory observations remain private and honest', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final memory in [
      const ModelHardware(
        appleSilicon: true,
        memoryBytes: 32 * gib,
        availableBytes: 0,
      ),
      const ModelHardware(appleSilicon: true, memoryBytes: 32 * gib),
      const ModelHardware(appleSilicon: false, detail: 'PRIVATE /secret'),
      const ModelHardware(
        appleSilicon: true,
        memoryBytes: -1,
        availableBytes: -1,
      ),
    ]) {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.5)),
              child: SingleChildScrollView(
                child: RuntimeCapabilityPanel(
                  report: RuntimeCapabilities.fromJson(discovery.report()),
                  selected: null,
                  backend: RuntimeBackend.auto,
                  memory: memory,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Host RAM: ${memory.memoryBytes == 32 * gib ? '32.0 GiB' : 'unknown'}; free/reclaimable: ${memory.availableBytes == 0 ? '0.0 GiB' : 'unknown'}.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Read-only snapshot'), findsOneWidget);
      expect(find.textContaining('PRIVATE'), findsNothing);
      expect(find.textContaining('memory adequacy check'), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
