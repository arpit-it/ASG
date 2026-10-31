// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/models/runtime_capabilities.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/views/runtime_setup_screen.dart';

import 'runtime_setup_test.dart' as fixture;

Map<String, dynamic> report({bool missing = false}) => {
  'schema_version': 1,
  'host': {'system': 'Darwin', 'machine': 'arm64'},
  'backends': [
    for (final kind in ['mlx', 'torch'])
      {
        'backend': kind,
        'device': kind == 'mlx' ? 'metal' : 'mps',
        'host_supported': true,
        'missing_dependencies': missing && kind == 'mlx'
            ? ['mlx_lm']
            : <String>[],
        'device_ready': null,
        'model_compatible': null,
        'readiness': missing && kind == 'mlx' ? 'unavailable' : 'unverified',
      },
  ],
};

class DiscoveryHost extends fixture.FakeRuntimeHost {
  int calls = 0;
  bool fail = false;
  String? python;
  Completer<void>? gate;
  @override
  Future<RuntimeCapabilities> discover(String python) async {
    calls++;
    this.python = python;
    await gate?.future;
    if (fail) throw StateError('PRIVATE /secret token=private');
    return RuntimeCapabilities.fromJson(report(missing: true));
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('discovery sanitizes host and rejects untrusted identity/readiness', () {
    final value = report();
    value['host'] = {'system': 'PRIVATE /secret', 'machine': 'token=private'};
    expect(
      RuntimeCapabilities.fromJson(value).host,
      'Unknown host / unknown architecture',
    );
    for (final mutation in <void Function(Map<String, dynamic>)>[
      (v) => v['schema_version'] = 2,
      (v) => v['backends'][0]['missing_dependencies'] = ['PRIVATE'],
      (v) => v['backends'][0]['device'] = 'cuda',
      (v) => v['backends'][0]['device_ready'] = true,
      (v) => v['backends'][0]['model_compatible'] = true,
      (v) => v['backends'][0]['readiness'] = 'ready',
      (v) => v['backends'][0]['host_supported'] = 'true',
      (v) => v['backends'][1] = v['backends'][0],
      (v) => v['backends'] = [],
    ]) {
      final v = report();
      mutation(v);
      expect(() => RuntimeCapabilities.fromJson(v), throwsFormatException);
    }
  });
  test(
    'dependencies, auto preference and metadata remain distinct from readiness',
    () {
      final caps = RuntimeCapabilities.fromJson(report(missing: true));
      expect(caps.host, 'macOS / ARM64');
      expect(caps.preferred.backend, RuntimeBackend.torch);
      expect(caps.backends.first.availability, contains('mlx_lm'));
      expect(caps.backends.last.availability, contains('unverified'));
      expect(caps.backends.last.modelCompatibility(null), contains('unknown'));
      const quantized = ModelCandidate(
        path: '/model',
        name: 'model',
        supported: true,
        detail: '',
        quantized: true,
      );
      expect(
        caps.backends.last.modelCompatibility(quantized),
        contains('Incompatible'),
      );
      expect(
        caps.backends.first.modelCompatibility(quantized),
        contains('remain unverified'),
      );
      final linux = report();
      linux['host']['system'] = 'Linux';
      for (final entry in linux['backends']) {
        entry['host_supported'] = false;
        entry['readiness'] = 'unavailable';
      }
      expect(
        RuntimeCapabilities.fromJson(linux).backends.first.availability,
        contains('Unavailable on this host'),
      );
      expect(() => caps.backends.clear(), throwsUnsupportedError);
      expect(
        () => caps.backends.first.missingDependencies.clear(),
        throwsUnsupportedError,
      );
    },
  );
  test('discovery preserves saved setup, chat and running runtime', () async {
    final host = DiscoveryHost()..ownsProcess = true;
    final c = await fixture.controller(host);
    addTearDown(c.dispose);
    c.initialize();
    const saved = RuntimeSetup(
      python: '/previous',
      backend: RuntimeBackend.mlx,
    );
    await c.saveSetup(saved);
    final prefs = await SharedPreferences.getInstance();
    final keys = jsonEncode(prefs.getKeys().toList()..sort());
    final raw = prefs.getString('studio.runtimeSetup.v1');
    await c.discover(' /python with spaces ');
    expect(host.python, '/python with spaces');
    expect(c.capabilities, isNotNull);
    expect(c.setup, same(saved));
    expect(prefs.getString('studio.runtimeSetup.v1'), raw);
    expect(jsonEncode(prefs.getKeys().toList()..sort()), keys);
    expect(host.ownsProcess, true);
    expect(host.stops, 0);
    expect(host.downloads, 0);
    c.invalidateCapabilities();
    expect(c.capabilities, isNull);
    await c.discover('/python');
    await c.inspect('/models');
    expect(c.capabilities, isNull);
    await c.discover('/python');
    c.select(c.candidates.single);
    expect(c.capabilities, isNull);
  });
  test('failure is private and retry clears stale result', () async {
    final host = DiscoveryHost();
    final c = await fixture.controller(host);
    addTearDown(c.dispose);
    await c.discover('/python');
    expect(c.capabilities, isNotNull);
    host.fail = true;
    await c.discover('/python');
    expect(c.capabilities, isNull);
    expect(c.error, contains('retry'));
    expect(c.error, isNot(contains('PRIVATE')));
    expect(c.error, isNot(contains('/secret')));
    host.fail = false;
    await c.discover('/python');
    expect(c.error, isNull);
    expect(c.capabilities, isNotNull);
  });
  test('busy, invalidation and disposal reject late discovery', () async {
    for (final dispose in [false, true]) {
      final host = DiscoveryHost()..gate = Completer<void>();
      final c = await fixture.controller(host);
      final pending = c.discover('/python');
      await c.discover('/other');
      expect(host.calls, 1);
      expect(c.busy, true);
      if (dispose) {
        c.dispose();
      } else {
        c.invalidateCapabilities();
      }
      host.gate!.complete();
      await pending;
      expect(c.capabilities, isNull);
      if (!dispose) c.dispose();
    }
  });
  testWidgets(
    '320px enlarged setup discovery invalidates on backend and Python edit',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await fixture.controller(DiscoveryHost());
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: RuntimeSetupScreen(controller: c),
        ),
      );
      await tester.pumpAndSettle();
      final inspect = find.text('Inspect capabilities');
      await tester.scrollUntilVisible(
        inspect,
        350,
        maxScrolls: 40,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(inspect);
      await tester.pumpAndSettle();
      await tester.tap(inspect);
      await tester.pumpAndSettle();
      expect(c.capabilities, isNotNull);
      expect(find.text('Detected host: macOS / ARM64'), findsOneWidget);
      expect(
        find.textContaining('Missing dependencies: mlx_lm'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      final dropdown = find.byType(DropdownButtonFormField<RuntimeBackend>);
      await tester.scrollUntilVisible(
        dropdown,
        -300,
        maxScrolls: 40,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text(RuntimeBackend.mlx.label).last);
      await tester.pumpAndSettle();
      expect(c.capabilities, isNull);
      await tester.scrollUntilVisible(
        inspect,
        350,
        maxScrolls: 40,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(inspect);
      await tester.pumpAndSettle();
      await tester.tap(inspect);
      await tester.pumpAndSettle();
      final python = find.widgetWithText(TextField, 'Python executable');
      await tester.scrollUntilVisible(
        python,
        -300,
        maxScrolls: 40,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(python);
      await tester.pumpAndSettle();
      await tester.enterText(python, '/changed python');
      await tester.pumpAndSettle();
      expect(c.capabilities, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
