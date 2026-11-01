// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/views/runtime_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cpu_checkpoint_view_test.dart' show field, reveal;
import 'runtime_setup_test.dart' as fixture;

Finder get launch =>
    find.widgetWithText(OutlinedButton, 'Launch experimental CPU');
Finder get consent => find.widgetWithText(
  CheckboxListTile,
  'Allow experimental CPU weight loading and launch',
);
Future<void> open(
  WidgetTester t,
  fixture.FakeRuntimeHost host, {
  bool narrow = false,
}) async {
  t.view.physicalSize = Size(narrow ? 320 : 1200, 1800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(narrow ? 1.8 : 1)),
        child: child!,
      ),
      home: RuntimeSetupScreen(controller: await fixture.controller(host)),
    ),
  );
  await t.pumpAndSettle();
  await reveal(t, field('Python executable'));
  await t.enterText(field('Python executable'), ' /python ');
  final title = find.text('Experimental CPU launch');
  await reveal(t, title);
  await t.tap(title);
  await t.pumpAndSettle();
}

Future<void> inputs(WidgetTester t) async {
  for (final entry in {
    'CPU launch checkpoint folder': ' /checkpoint ',
    'CPU launch model ID': ' cpu-model ',
  }.entries) {
    await reveal(t, field(entry.key));
    await t.enterText(field(entry.key), entry.value);
  }
  await reveal(t, consent);
  await t.tap(consent);
  await t.pumpAndSettle();
  await reveal(t, launch);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'consent and independent inputs gate trimmed bounded launch without persistence',
    (t) async {
      final host = fixture.CpuLaunchRuntimeHost();
      await open(t, host);
      expect(t.widget<OutlinedButton>(launch).onPressed, isNull);
      await inputs(t);
      await t.tap(consent);
      await t.pump();
      expect(t.widget<OutlinedButton>(launch).onPressed, isNull);
      await t.tap(consent);
      await t.pump();
      await t.tap(launch);
      await t.pumpAndSettle();
      expect(host.launches, 1);
      expect(host.received!.python, '/python');
      expect(host.received!.modelPath, '/checkpoint');
      expect(host.model, 'cpu-model');
      expect(host.threads, 2);
      expect(host.deadline, const Duration(seconds: 180));
      expect(host.ceiling, isNull);
      expect(t.widget<OutlinedButton>(launch).onPressed, isNull);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      expect(find.textContaining('Verify health separately'), findsOneWidget);
    },
  );
  testWidgets(
    'busy exclusion private failure retry and stop pending acquisition',
    (t) async {
      final host = fixture.CpuLaunchRuntimeHost()
        ..fail = true
        ..gate = Completer<void>();
      await open(t, host);
      await inputs(t);
      await t.tap(launch);
      await t.pump();
      expect(t.widget<OutlinedButton>(launch).onPressed, isNull);
      expect(t.widget<CheckboxListTile>(consent).onChanged, isNull);
      host.gate!.complete();
      await t.pumpAndSettle();
      expect(
        find.textContaining('Could not launch experimental CPU.'),
        findsOneWidget,
      );
      expect(find.textContaining('PRIVATE_CPU'), findsNothing);
      host.fail = false;
      host.gate = Completer<void>();
      await reveal(t, launch);
      await t.tap(launch);
      await t.pump();
      final stop = find.widgetWithText(OutlinedButton, 'Stop CPU launch');
      await t.ensureVisible(stop);
      await t.pump();
      await t.tap(stop);
      await t.pump();
      host.gate!.complete();
      await t.pumpAndSettle();
      expect(host.launches, 2);
      expect(host.ownsProcess, false);
      expect(host.stops, 1);
    },
  );
  testWidgets('late close cleans acquired process and consent resets', (
    t,
  ) async {
    final host = fixture.CpuLaunchRuntimeHost()..gate = Completer<void>();
    await open(t, host);
    await inputs(t);
    await t.tap(launch);
    await t.pump();
    await t.pumpWidget(const SizedBox());
    host.gate!.complete();
    await t.pumpAndSettle();
    expect(host.ownsProcess, false);
    expect(t.takeException(), isNull);
    await open(t, fixture.CpuLaunchRuntimeHost());
    expect(t.widget<CheckboxListTile>(consent).value, false);
  });
  testWidgets('legacy and unsupported hosts have no CPU launch', (t) async {
    for (final host in [
      fixture.FakeRuntimeHost(),
      fixture.CpuLaunchRuntimeHost(supported: false),
    ]) {
      await t.pumpWidget(
        MaterialApp(
          home: RuntimeSetupScreen(controller: await fixture.controller(host)),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Experimental CPU launch'), findsNothing);
      await t.pumpWidget(const SizedBox());
    }
  });
  testWidgets('narrow enlarged text can fill and launch', (t) async {
    final host = fixture.CpuLaunchRuntimeHost();
    await open(t, host, narrow: true);
    await inputs(t);
    await t.tap(launch);
    await t.pumpAndSettle();
    expect(host.launches, 1);
    expect(t.takeException(), isNull);
  });
}
