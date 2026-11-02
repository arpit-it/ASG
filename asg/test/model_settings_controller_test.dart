// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';
import 'package:asg/views/model_settings.dart';
import 'package:asg/models/model_format_probe.dart';

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
  String? prompt;
  @override
  Stream<String> generate(String prompt) {
    this.prompt = prompt;
    return output.stream;
  }

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
    'completed tests measure first nonblank text and total elapsed per request',
    () async {
      var now = const Duration(seconds: 4);
      var provider = Probe();
      final c = ModelSettingsController(
        store,
        createProvider: (_) => provider,
        elapsed: () => now,
      );
      addTearDown(c.dispose);
      for (final json in [false, true]) {
        final pending = c.test(
          const LocalModelConfig(model: 'timed'),
          jsonFormat: json,
        );
        expect(c.status, isNot(contains('Client-observed first text:')));
        now += const Duration(milliseconds: 50);
        provider.output.add('  \n');
        await Future<void>.delayed(Duration.zero);
        now += const Duration(milliseconds: 75);
        provider.output.add(json ? '{"asg_probe":"ok"}' : 'private-answer');
        await Future<void>.delayed(Duration.zero);
        expect(c.status, isNot(contains('Client-observed first text:')));
        now += const Duration(milliseconds: 125);
        await provider.output.close();
        await pending;
        expect(
          c.status,
          contains('first text: 125 ms; completed response: 250 ms'),
        );
        expect(c.status, contains('Requested model ID: timed'));
        expect(c.status, isNot(contains('private-answer')));
        expect(store.loadPresets(), isEmpty);
        expect(store.load().model, const LocalModelConfig().model);
        provider = Probe();
      }
    },
  );

  test('draft changes clear observations without writes and cannot unlock active tests', () async {
    var provider = Probe();
    final seen = <LocalModelConfig>[];
    final c = ModelSettingsController(
      store,
      createProvider: (config) {
        seen.add(config);
        return provider;
      },
    );
    await c.savePreset('Preset', const LocalModelConfig(model: 'preset'));
    for (final json in [false, true]) {
      final pending = c.test(
        const LocalModelConfig(model: 'old'),
        jsonFormat: json,
      );
      final activeStatus = c.status;
      c.connectionDraftChanged();
      expect(c.busy, isTrue);
      expect(c.testing, isTrue);
      expect(c.status, activeStatus);
      provider.output.add(json ? '{"asg_probe":"ok"}' : 'private');
      await provider.output.close();
      await pending;
      final completed = c.status;
      expect(completed, contains('Client-observed first text:'));
      await c.savePreset(json ? 'JSON' : 'Text', const LocalModelConfig());
      expect(c.status, completed);
      c.inventoryStatus = 'Old inventory';
      if (json) {
        c.selectPreset('Preset');
      } else {
        c.connectionDraftChanged();
      }
      expect(c.status, ModelSettingsController.draftChangedGuidance);
      expect(c.inventoryStatus, isNull);
      expect(c.status, isNot(contains('old')));
      expect(store.load().model, const LocalModelConfig().model);
      expect(seen.length, json ? 2 : 1);
      provider = Probe();
    }
    final retry = c.test(const LocalModelConfig(model: 'new'));
    provider.output.addError(StateError('private'));
    unawaited(provider.output.close());
    await retry;
    expect(seen.last.model, 'new');
    expect(c.status, contains('failed'));
    c.connectionDraftChanged();
    expect(c.status, ModelSettingsController.draftChangedGuidance);
    c.dispose();
    final closed = c.status;
    c.connectionDraftChanged();
    expect(c.status, closed);
  });

  testWidgets(
    'connection edits clear status but preset names and notes do not',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ModelSettings(store: store)),
        ),
      );
      final fields = tester
          .widgetList<TextField>(find.byType(TextField))
          .toList();
      final url = fields[0].controller!;
      final model = fields[1].controller!;
      url.text = 'http://private@localhost';
      await tester.pump();
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test model'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Invalid connection settings'),
        findsOneWidget,
      );
      model.text = 'new-model';
      await tester.pump();
      expect(
        find.text(ModelSettingsController.draftChangedGuidance),
        findsOneWidget,
      );
      expect(find.textContaining('Invalid connection settings'), findsNothing);
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test JSON format'));
      await tester.pumpAndSettle();
      fields[2].controller!.text = 'name';
      model.selection = const TextSelection.collapsed(offset: 1);
      final tile = find.widgetWithText(
        ExpansionTile,
        'Unverified model profile notes',
      );
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      tester
              .widget<TextField>(find.byKey(const ValueKey('License note')))
              .controller!
              .text =
          'license';
      await tester.pump();
      expect(
        find.textContaining('Invalid connection settings'),
        findsOneWidget,
      );
      final tokens = find.byType(DropdownButtonFormField<int>);
      await tester.ensureVisible(tokens);
      await tester.tap(tokens);
      await tester.pumpAndSettle();
      await tester.tap(find.text('512').last);
      await tester.pumpAndSettle();
      expect(
        find.text(ModelSettingsController.draftChangedGuidance),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(OutlinedButton, 'Test model'));
      await tester.pumpAndSettle();
      url.text = 'http://localhost:9876/v1';
      await tester.pump();
      expect(
        find.text(ModelSettingsController.draftChangedGuidance),
        findsOneWidget,
      );
      expect(store.load().model, const LocalModelConfig().model);
      expect(tester.takeException(), isNull);
    },
  );

  test('JSON format observation requires one exact duplicate-free object', () {
    for (final text in [
      '{"asg_probe":"ok"}',
      ' \n { "asg_probe" : "ok" } \t',
      r'{"asg_\u0070robe":"ok"}',
    ]) {
      expect(ModelFormatProbe.accepts(text), isTrue, reason: text);
    }
    for (final text in [
      '',
      'ok',
      '```json\n{"asg_probe":"ok"}\n```',
      '[]',
      'null',
      '1',
      '"ok"',
      '{"asg_probe":true}',
      '{"asg_probe":"wrong"}',
      '{"asg_probe":"ok","extra":1}',
      '{"asg_probe":"wrong","asg_probe":"ok"}',
      r'{"asg_probe":"wrong","asg_\u0070robe":"ok"}',
      '{"asg_probe":"ok"} trailing',
      '{"asg_probe":',
    ]) {
      expect(ModelFormatProbe.accepts(text), isFalse, reason: text);
    }
  });
  test(
    'JSON probe is completed, bounded, private and leaves settings unchanged',
    () async {
      for (final kind in [
        'valid',
        'wrong',
        'empty',
        'error',
        'large',
        'stop',
      ]) {
        final p = Probe();
        final c = ModelSettingsController(store, createProvider: (_) => p);
        final pending = c.test(
          const LocalModelConfig(model: 'chosen'),
          jsonFormat: true,
        );
        expect(p.prompt, ModelFormatProbe.prompt);
        await c.test(const LocalModelConfig(model: 'other'));
        expect(c.busy, isTrue);
        p.output.add('{"asg_probe":');
        await Future<void>.delayed(Duration.zero);
        expect(c.status, contains('Waiting for a completed'));
        if (kind == 'stop') {
          c.stopTest();
        } else if (kind == 'error') {
          p.output.addError(StateError('private-marker'));
        } else {
          p.output.add(
            kind == 'valid'
                ? '"ok"}'
                : kind == 'large'
                ? 'private-marker' * 500
                : kind == 'empty'
                ? ''
                : '"private-marker"}',
          );
        }
        unawaited(p.output.close());
        await pending;
        expect(c.busy, isFalse);
        expect(p.cancelled, isTrue);
        expect(c.status, isNot(contains('private-marker')));
        if (kind == 'valid') {
          expect(c.status, contains('expected JSON object in one completed'));
          expect(c.status, contains('Requested model ID: chosen'));
          expect(c.status, contains('unverified'));
        } else {
          expect(c.status, isNot(contains('Client-observed first text:')));
          expect(
            c.status,
            isNot(contains('expected JSON object in one completed')),
          );
        }
        expect(store.load().model, const LocalModelConfig().model);
        expect(store.loadPresets(), isEmpty);
        c.dispose();
      }
    },
  );
  testWidgets(
    'JSON probe deadline and disposal never publish partial success',
    (tester) async {
      for (final dispose in [false, true]) {
        final p = Probe();
        final c = ModelSettingsController(store, createProvider: (_) => p);
        final pending = c.test(const LocalModelConfig(), jsonFormat: true);
        p.output.add('{"asg_probe":"ok"}');
        await tester.pump();
        expect(c.busy, isTrue);
        if (dispose) {
          c.dispose();
        } else {
          await tester.pump(ModelSettingsController.probeTimeout);
        }
        await pending;
        expect(
          c.status,
          isNot(contains('expected JSON object in one completed')),
        );
        expect(p.cancelled, isTrue);
        expect(c.status, isNot(contains('Client-observed first text:')));
        unawaited(p.output.close());
        if (!dispose) c.dispose();
      }
    },
  );
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
    tester.view.physicalSize = const Size(320, 720);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(body: ModelSettings(store: store)),
      ),
    );
    expect(find.text(ModelSettingsController.requestLimits), findsOneWidget);
    expect(find.text('Test JSON format'), findsOneWidget);
    expect(find.text('Test JSON format').hitTestable(), findsOneWidget);
    expect(find.text(ModelFormatProbe.guidance), findsOneWidget);
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
