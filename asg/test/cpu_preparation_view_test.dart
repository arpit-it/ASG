// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/views/runtime_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cpu_checkpoint_view_test.dart' show field, reveal;
import 'runtime_setup_test.dart' as fixture;

Finder get check =>
    find.widgetWithText(OutlinedButton, 'Check CPU dependencies');
Finder get consent => find.widgetWithText(
  CheckboxListTile,
  'Allow this experimental CPU dependency check',
);
Future<void> open(WidgetTester t, fixture.FakeRuntimeHost host) async {
  t.view.physicalSize = const Size(1200, 1800);
  t.view.devicePixelRatio = 1;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);
  await t.pumpWidget(
    MaterialApp(
      home: RuntimeSetupScreen(controller: await fixture.controller(host)),
    ),
  );
  await t.pumpAndSettle();
  final title = find.text('Experimental CPU dependency check');
  await reveal(t, title);
  await t.tap(title);
  await t.pumpAndSettle();
}

Future<void> allow(WidgetTester t) async {
  await reveal(t, field('Python executable'));
  await t.enterText(field('Python executable'), ' /python with spaces ');
  await reveal(t, consent);
  await t.tap(consent);
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets('explicit consent and Python gate dependency-only action', (
    t,
  ) async {
    final host = fixture.CpuPrepareRuntimeHost()..fail = false;
    await open(t, host);
    expect(t.widget<OutlinedButton>(check).onPressed, isNull);
    await reveal(t, field('Python executable'));
    await t.enterText(field('Python executable'), ' ');
    await reveal(t, consent);
    await t.tap(consent);
    await t.pump();
    expect(t.widget<OutlinedButton>(check).onPressed, isNull);
    await t.tap(consent);
    await allow(t);
    await reveal(t, check);
    await t.tap(check);
    await t.pumpAndSettle();
    expect(host.preparations, 1);
    expect(host.cpuPython, '/python with spaces');
    expect(host.consent, true);
    expect(
      find.textContaining('Experimental CPU dependencies checked.'),
      findsOneWidget,
    );
    expect(
      find.textContaining('inference remain unverified.'),
      findsNWidgets(2),
    );
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
    expect(host.stops, 0);
    expect(host.downloads, 0);
    expect(host.ownsProcess, false);
    await reveal(t, consent);
    await t.tap(consent);
    await t.pump();
    expect(t.widget<OutlinedButton>(check).onPressed, isNull);
  });
  testWidgets('busy controls, private failure and retry', (t) async {
    final host = fixture.CpuPrepareRuntimeHost()..gate = Completer<void>();
    await open(t, host);
    await allow(t);
    await reveal(t, check);
    await t.tap(check);
    await t.pump();
    expect(t.widget<OutlinedButton>(check).onPressed, isNull);
    expect(t.widget<CheckboxListTile>(consent).onChanged, isNull);
    expect(t.widget<TextField>(field('Python executable')).enabled, false);
    expect(host.preparations, 1);
    host.gate!.complete();
    await t.pumpAndSettle();
    expect(
      find.textContaining('Could not check experimental CPU dependencies.'),
      findsOneWidget,
    );
    expect(find.textContaining('PRIVATE_PREPARE'), findsNothing);
    host.fail = false;
    await reveal(t, check);
    await t.tap(check);
    await t.pumpAndSettle();
    expect(host.preparations, 2);
    expect(
      find.textContaining('Could not check experimental CPU dependencies.'),
      findsNothing,
    );
  });
  testWidgets('legacy and unsupported hosts have no experimental check', (
    t,
  ) async {
    for (final host in [
      fixture.FakeRuntimeHost(),
      fixture.FakeRuntimeHost(supported: false),
    ]) {
      await t.pumpWidget(
        MaterialApp(
          home: RuntimeSetupScreen(controller: await fixture.controller(host)),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Experimental CPU dependency check'), findsNothing);
      await t.pumpWidget(const SizedBox());
    }
  });
  testWidgets('late completion after close is safe and consent resets', (
    t,
  ) async {
    final host = fixture.CpuPrepareRuntimeHost()
      ..fail = false
      ..gate = Completer<void>();
    await open(t, host);
    await allow(t);
    await reveal(t, check);
    await t.tap(check);
    await t.pump();
    await t.pumpWidget(const SizedBox());
    host.gate!.complete();
    await t.pumpAndSettle();
    expect(t.takeException(), isNull);
    await open(t, fixture.CpuPrepareRuntimeHost());
    expect(t.widget<CheckboxListTile>(consent).value, false);
    expect(t.widget<OutlinedButton>(check).onPressed, isNull);
  });
  testWidgets('narrow enlarged text check remains usable', (t) async {
    t.view.physicalSize = const Size(320, 1500);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.8)),
          child: child!,
        ),
        home: RuntimeSetupScreen(
          controller: await fixture.controller(fixture.CpuPrepareRuntimeHost()),
        ),
      ),
    );
    await t.pumpAndSettle();
    final title = find.text('Experimental CPU dependency check');
    await reveal(t, title);
    await t.tap(title);
    await t.pumpAndSettle();
    await reveal(t, check);
    expect(t.takeException(), isNull);
  });
}
