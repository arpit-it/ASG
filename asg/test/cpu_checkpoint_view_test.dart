// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/models/runtime_setup.dart';
import 'package:asg/views/runtime_setup_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'cpu_checkpoint_controller_test.dart' as cpu;
import 'runtime_setup_test.dart' as fixture;

Finder field(String label) => find.byWidgetPredicate(
  (w) => w is TextField && w.decoration?.labelText == label,
);
Finder get inspect =>
    find.widgetWithText(OutlinedButton, 'Inspect CPU checkpoint');
Future<void> reveal(WidgetTester t, Finder f) async {
  if (f.evaluate().isEmpty) {
    await t.scrollUntilVisible(
      f,
      300,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await t.ensureVisible(f);
  await t.pumpAndSettle();
}

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
  final title = find.text('Experimental CPU checkpoint inspection');
  if (title.evaluate().isNotEmpty) {
    await reveal(t, title);
    await t.tap(title);
    await t.pumpAndSettle();
  }
}

Future<void> inputs(WidgetTester t) async {
  await reveal(t, field('Python executable'));
  await t.enterText(field('Python executable'), ' /python with spaces ');
  await reveal(t, field('Experimental CPU checkpoint folder'));
  await t.enterText(
    field('Experimental CPU checkpoint folder'),
    ' /cpu checkpoint ',
  );
  await t.pumpAndSettle();
}

Future<void> consent(WidgetTester t) async {
  final f = find.byType(CheckboxListTile);
  await reveal(t, f);
  await t.tap(f);
  await t.pumpAndSettle();
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'consent and exact ceiling gate no-load inspection without changing setup',
    (t) async {
      final host = cpu.InspectionHost()..ownsProcess = true;
      await open(t, host);
      await inputs(t);
      expect(t.widget<OutlinedButton>(inspect).onPressed, isNull);
      await consent(t);
      final limit = field('Optional maximum weight bytes on disk');
      for (final value in ['0', '-1', '1.5', '9007199254740992', '1e3']) {
        await reveal(t, limit);
        await t.enterText(limit, value);
        await t.pump();
        expect(t.widget<OutlinedButton>(inspect).onPressed, isNull);
      }
      await t.enterText(limit, ' 9007199254740991 ');
      await t.pump();
      await reveal(t, inspect);
      await t.tap(inspect);
      await t.pumpAndSettle();
      expect(host.inspections, 1);
      expect(host.python, '/python with spaces');
      expect(host.path, '/cpu checkpoint');
      expect(host.ceiling, 9007199254740991);
      expect(find.text('Observed weight bytes on disk: 1234'), findsOneWidget);
      expect(find.text('Distinct weight files: 2'), findsOneWidget);
      expect(find.text('CPU inference readiness: unverified'), findsOneWidget);
      expect(host.stops, 0);
      expect(host.downloads, 0);
      expect(host.preparations, 0);
      expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
      expect(RuntimeBackend.values.length, 3);
      await consent(t);
      expect(find.text('Observed weight bytes on disk: 1234'), findsNothing);
      expect(t.widget<OutlinedButton>(inspect).onPressed, isNull);
    },
  );
  testWidgets(
    'busy exclusion, private failure, retry and Python invalidation',
    (t) async {
      final host = cpu.InspectionHost()
        ..gate = Completer<void>()
        ..fail = true;
      await open(t, host);
      await inputs(t);
      await consent(t);
      await reveal(t, inspect);
      await t.tap(inspect);
      await t.pump();
      expect(host.inspections, 1);
      expect(t.widget<OutlinedButton>(inspect).onPressed, isNull);
      expect(
        t
            .widget<TextField>(field('Experimental CPU checkpoint folder'))
            .enabled,
        isFalse,
      );
      expect(
        t.widget<CheckboxListTile>(find.byType(CheckboxListTile)).onChanged,
        isNull,
      );
      host.gate!.complete();
      await t.pumpAndSettle();
      expect(
        find.textContaining(
          'Could not inspect the experimental CPU checkpoint',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('PRIVATE_CPU'), findsNothing);
      host.fail = false;
      await reveal(t, inspect);
      await t.tap(inspect);
      await t.pumpAndSettle();
      expect(host.inspections, 2);
      expect(host.ceiling, isNull);
      expect(find.text('Observed weight bytes on disk: 1234'), findsOneWidget);
      await reveal(t, field('Python executable'));
      await t.enterText(field('Python executable'), '/other');
      await t.pump();
      expect(find.text('Observed weight bytes on disk: 1234'), findsNothing);
    },
  );
  testWidgets('checkpoint and ceiling changes clear observations', (t) async {
    await open(t, cpu.InspectionHost());
    await inputs(t);
    await consent(t);
    for (final label in [
      'Experimental CPU checkpoint folder',
      'Optional maximum weight bytes on disk',
    ]) {
      await reveal(t, inspect);
      await t.tap(inspect);
      await t.pumpAndSettle();
      expect(find.text('Observed weight bytes on disk: 1234'), findsOneWidget);
      await reveal(t, field(label));
      await t.enterText(
        field(label),
        label.startsWith('Optional') ? '2000' : '/changed',
      );
      await t.pump();
      expect(find.text('Observed weight bytes on disk: 1234'), findsNothing);
    }
  });
  testWidgets('optional view absent for legacy and unsupported hosts', (
    t,
  ) async {
    for (final host in [
      fixture.FakeRuntimeHost(),
      cpu.InspectionHost(supported: false),
    ]) {
      await open(t, host);
      expect(find.text('Experimental CPU checkpoint inspection'), findsNothing);
      await t.pumpWidget(const SizedBox());
    }
  });
  testWidgets('narrow enlarged text panel remains usable', (t) async {
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
          controller: await fixture.controller(cpu.InspectionHost()),
        ),
      ),
    );
    await t.pumpAndSettle();
    final title = find.text('Experimental CPU checkpoint inspection');
    await reveal(t, title);
    await t.tap(title);
    await t.pumpAndSettle();
    await reveal(t, inspect);
    expect(t.takeException(), isNull);
  });
}
