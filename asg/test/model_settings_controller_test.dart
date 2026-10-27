import 'package:flutter/material.dart';
import 'package:asg/views/model_settings.dart';

import 'dart:async';

import 'package:asg/controllers/model_settings_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class Probe implements ModelProvider {
  final output = StreamController<String>();
  bool cancelled = false;
  @override
  Stream<String> generate(String prompt) => output.stream;
  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}

void main() {
  late ModelSettingsStore store;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    store = ModelSettingsStore.fromPreferences(
      await SharedPreferences.getInstance(),
    );
  });
  test(
    'invalid saves explain settings and preserve saved configuration',
    () async {
      final c = ModelSettingsController(store);
      const original = LocalModelConfig(model: 'existing-model');
      await c.save(original);
      for (final invalid in [
        const LocalModelConfig(baseUrl: 'http://private@example.com'),
        const LocalModelConfig(model: ''),
      ]) {
        await c.save(invalid);
        expect(c.status, contains('Invalid connection settings'));
        expect(c.status, isNot(contains('private@')));
        expect(store.load().model, original.model);
        expect(store.load().baseUrl, original.baseUrl);
      }
      c.dispose();
    },
  );
  testWidgets('connection limits fit narrow enlarged dialog', (tester) async {
    tester.view.physicalSize = const Size(360, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
    expect(find.text(ModelSettingsController.requestLimits), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test('diagnostics omit response and errors; empty response fails', () async {
    for (final kind in ['success', 'empty', 'error', 'timeout', 'large']) {
      final p = Probe();
      final c = ModelSettingsController(store, createProvider: (_) => p);
      final pending = c.test(const LocalModelConfig());
      if (kind == 'error') {
        p.output.addError(StateError('fixture-secret'));
      } else if (kind == 'timeout') {
        p.output.addError(TimeoutException('fixture-secret'));
      } else {
        p.output.add(
          kind == 'empty'
              ? '  '
              : kind == 'large'
              ? 'x' * 4097
              : 'fixture-secret',
        );
      }
      unawaited(p.output.close());
      await pending;
      expect(c.status, isNot(contains('fixture-secret')));
      expect(
        c.status,
        contains(switch (kind) {
          'success' => 'completed',
          'empty' => 'no text',
          'timeout' => 'timed out',
          'large' => 'text limit',
          _ => 'failed',
        }),
      );
      expect(c.busy, isFalse);
      expect(p.cancelled, isTrue);
      c.dispose();
    }
  });
  testWidgets('total deadline releases stalled request', (tester) async {
    final p = Probe();
    final c = ModelSettingsController(store, createProvider: (_) => p);
    final pending = c.test(const LocalModelConfig());
    await tester.pump(ModelSettingsController.probeTimeout);
    await pending;
    expect(c.status, contains('timed out'));
    p.output.add('late secret');
    await tester.pump();
    expect(c.status, contains('timed out'));
    unawaited(p.output.close());
    c.dispose();
  });
  test('stop releases request, permits retry and ignores old output', () async {
    final probes = [Probe(), Probe()];
    var next = 0;
    final c = ModelSettingsController(
      store,
      createProvider: (_) => probes[next++],
    );
    final first = c.test(const LocalModelConfig());
    c.stopTest();
    await first;
    expect(c.status, contains('server-side inference may continue'));
    final second = c.test(const LocalModelConfig());
    probes.first.output.add('late secret');
    await probes.first.output.close();
    expect(c.testing, isTrue);
    probes.last.output.add('OK');
    unawaited(probes.last.output.close());
    await second;
    expect(c.status, contains('completed'));
    c.dispose();
  });
  test(
    'invalid settings refuse before provider creation; disposal completes',
    () async {
      final p = Probe();
      var calls = 0;
      final c = ModelSettingsController(
        store,
        createProvider: (_) {
          calls++;
          return p;
        },
      );
      await c.test(
        const LocalModelConfig(baseUrl: 'http://secret@example.com'),
      );
      expect(calls, 0);
      expect(c.status, isNot(contains('secret@')));
      final active = c.test(const LocalModelConfig());
      c.dispose();
      await active;
      expect(p.cancelled, isTrue);
      unawaited(p.output.close());
    },
  );
}
