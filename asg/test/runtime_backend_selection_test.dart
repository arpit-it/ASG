// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/runtime_setup_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/runtime_connection.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/views/runtime_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'runtime_setup_test.dart' show FakeRuntimeHost;

class BlockingSetupStore extends RuntimeSetupStore {
  BlockingSetupStore(super.records);
  final entered = Completer<void>(), release = Completer<void>();
  bool fail = false;
  int writes = 0;
  @override
  Future<void> save(RuntimeSetup value) async {
    writes++;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    if (fail) throw StateError('PRIVATE_SETTINGS');
    await super.save(value);
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  Future<RuntimeSetupController> create({
    RuntimeSetupStore? store,
    RuntimeConnection? api,
    FakeRuntimeHost? host,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    return RuntimeSetupController(
      store: store ?? RuntimeSetupStore.fromPreferences(prefs),
      modelStore: ModelSettingsStore.fromPreferences(prefs),
      host: host ?? FakeRuntimeHost(),
      connection:
          api ??
          RuntimeConnection(
            client: MockClient(
              (_) async => http.Response('{"status":"loading"}', 200),
            ),
          ),
    );
  }

  test(
    'legacy default and each explicit backend survive store reopen',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = RuntimeSetupStore.fromPreferences(prefs);
      expect(store.load().backend, RuntimeBackend.auto);
      final legacy = const RuntimeSetup().toJson()..remove('backend');
      await prefs.setString('studio.runtimeSetup.v1', jsonEncode(legacy));
      expect(store.load().backend, RuntimeBackend.auto);
      for (final backend in RuntimeBackend.values) {
        await store.save(RuntimeSetup(backend: backend));
        expect(
          RuntimeSetupStore.fromPreferences(prefs).load().backend,
          backend,
        );
      }
      for (final invalid in ['cuda', 1, [], {}]) {
        await prefs.setString(
          'studio.runtimeSetup.v1',
          jsonEncode({...legacy, 'backend': invalid}),
        );
        expect(store.load, throwsFormatException);
      }
    },
  );
  test('invalid saved backend cannot be replaced by default setup', () async {
    final prefs = await SharedPreferences.getInstance();
    final raw = jsonEncode({
      ...const RuntimeSetup().toJson(),
      'backend': 'cuda',
    });
    await prefs.setString('studio.runtimeSetup.v1', raw);
    final c = await create();
    c.initialize();
    await c.saveSetup(const RuntimeSetup(backend: RuntimeBackend.mlx));
    expect(c.error, contains('not been overwritten'));
    expect(prefs.getString('studio.runtimeSetup.v1'), raw);
    c.dispose();
  });
  test('save is durable without connection or process changes', () async {
    final host = FakeRuntimeHost()..ownsProcess = true;
    final c = await create(host: host);
    c.initialize();
    final oldConfig = c.connectionConfig;
    await c.saveSetup(const RuntimeSetup(backend: RuntimeBackend.torch));
    expect(c.setup.backend, RuntimeBackend.torch);
    expect(c.store.load().backend, RuntimeBackend.torch);
    expect(c.connectionConfig, same(oldConfig));
    expect(host.ownsProcess, isTrue);
    expect(host.downloads, 0);
    expect(host.stops, 0);
    expect(c.status, contains('unchanged'));
    c.dispose();
  });
  for (final close in [false, true]) {
    test(
      'pending save guards overlap and late publication; disposed=$close',
      () async {
        final prefs = await SharedPreferences.getInstance();
        final store = BlockingSetupStore(
          RuntimeSetupStore.fromPreferences(prefs).records,
        );
        final c = await create(store: store);
        c.initialize();
        final pending = c.saveSetup(
          const RuntimeSetup(backend: RuntimeBackend.torch),
        );
        await store.entered.future;
        expect(c.setup.backend, RuntimeBackend.auto);
        await c.saveSetup(const RuntimeSetup(backend: RuntimeBackend.mlx));
        expect(store.writes, 1);
        if (close) c.dispose();
        store.release.complete();
        await pending;
        expect(store.load().backend, RuntimeBackend.torch);
        expect(
          c.setup.backend,
          close ? RuntimeBackend.auto : RuntimeBackend.torch,
        );
        if (!close) c.dispose();
      },
    );
  }
  test(
    'failed save preserves choice and private errors, permits retry',
    () async {
      final prefs = await SharedPreferences.getInstance();
      final store = BlockingSetupStore(
        RuntimeSetupStore.fromPreferences(prefs).records,
      )..fail = true;
      final c = await create(store: store);
      c.initialize();
      store.release.complete();
      await c.saveSetup(const RuntimeSetup(backend: RuntimeBackend.torch));
      expect(c.setup.backend, RuntimeBackend.auto);
      expect(store.load().backend, RuntimeBackend.auto);
      expect(c.error, contains('could not be saved'));
      expect(c.error, isNot(contains('PRIVATE')));
      store.fail = false;
      await c.saveSetup(const RuntimeSetup(backend: RuntimeBackend.torch));
      expect(store.load().backend, RuntimeBackend.torch);
      expect(c.error, isNull);
      c.dispose();
    },
  );
  test('startup and download retain explicitly chosen backend', () async {
    final host = FakeRuntimeHost();
    final c = await create(
      host: host,
      api: RuntimeConnection(
        client: MockClient(
          (_) async => http.Response(
            jsonEncode({
              'status': host.ownsProcess ? 'ready' : 'loading',
              'model': 'Qwen3.5-9B',
              'model_path': '/models/Qwen3.5-9B',
            }),
            200,
          ),
        ),
      ),
    );
    c.initialize();
    await Future<void>.delayed(Duration.zero);
    await c.download(
      const RuntimeSetup(
        repository: 'owner/model',
        backend: RuntimeBackend.torch,
      ),
    );
    expect(c.setup.backend, RuntimeBackend.torch);
    await c.start(c.setup);
    expect(c.error, isNull);
    expect(c.store.load().backend, RuntimeBackend.torch);
    c.dispose();
  });
  test('only recognized ready backend/device pairs reach the model', () async {
    for (final status in ['ready', 'loading', 'error']) {
      for (final pair in [
        ('mlx', 'metal', LoadedRuntimeDevice.mlxMetal),
        ('torch', 'mps', LoadedRuntimeDevice.torchMps),
        ('torch', 'cpu', LoadedRuntimeDevice.torchCpu),
        ('cpu', 'cpu', null),
        ('torch', 'cuda', null),
        ('mlx', 'cpu', null),
        ('PRIVATE', '/private/device', null),
        (null, null, null),
        (['mlx'], {'device': 'metal'}, null),
      ]) {
        final api = RuntimeConnection(
          client: MockClient(
            (_) async => http.Response(
              jsonEncode({
                'status': status,
                'backend': pair.$1,
                'device': pair.$2,
              }),
              200,
            ),
          ),
        );
        final health = await api.check(const LocalModelConfig());
        expect(health.loadedDevice, status == 'ready' ? pair.$3 : null);
        expect(health.detail, isNot(contains('PRIVATE')));
        api.close();
      }
    }
  });
  testWidgets(
    'narrow enlarged setup saves choice and shows reported identity',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await create(
        api: RuntimeConnection(
          client: MockClient(
            (_) async => http.Response(
              '{"status":"ready","backend":"mlx","device":"metal"}',
              200,
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: RuntimeSetupScreen(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining(
          'Runtime reports loaded backend/device: MLX / Metal',
        ),
        findsOneWidget,
      );
      final dropdown = find.byType(DropdownButtonFormField<RuntimeBackend>);
      await tester.scrollUntilVisible(
        dropdown,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Torch / MPS').last);
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Save runtime setup'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save runtime setup'));
      await tester.pumpAndSettle();
      expect(c.store.load().backend, RuntimeBackend.torch);
      expect(c.health.loadedDevice, LoadedRuntimeDevice.mlxMetal);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'experimental CPU health is visible without enabling a launch choice',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await create(
        api: RuntimeConnection(
          client: MockClient(
            (_) async => http.Response(
              '{"status":"ready","phase":"idle","backend":"torch","device":"cpu"}',
              200,
            ),
          ),
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: RuntimeSetupScreen(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      expect(c.health.loadedDevice, LoadedRuntimeDevice.torchCpu);
      expect(
        find.textContaining(
          'Torch / CPU (experimental; real-host inference unverified)',
        ),
        findsOneWidget,
      );
      expect(c.setup.backend, RuntimeBackend.auto);
      final dropdown = find.byType(DropdownButtonFormField<RuntimeBackend>);
      await tester.scrollUntilVisible(
        dropdown,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      expect(find.text('Auto (legacy preference)').last, findsOneWidget);
      expect(find.text('MLX / Metal'), findsOneWidget);
      expect(find.text('Torch / MPS'), findsOneWidget);
      expect(find.text('Torch / CPU'), findsNothing);
      expect(RuntimeBackend.values, [
        RuntimeBackend.auto,
        RuntimeBackend.mlx,
        RuntimeBackend.torch,
      ]);
      expect(c.store.load().backend, RuntimeBackend.auto);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
