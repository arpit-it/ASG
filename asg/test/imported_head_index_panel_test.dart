// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_head_index_observation.dart';
import 'package:asg/views/imported_head_index_panel.dart';

import 'imported_index_controller_test.dart' as baseline;
import 'imported_head_index_controller_test.dart';
import 'imported_head_index_observation_test.dart'
    show headIndexObservationData;

void main() {
  testWidgets(
    'startup and cancelled consent never read; confirmed selection shows separate comparisons',
    (tester) async {
      final r = await baseline.indexRecords();
      final workfile = await readyWorkfile(r);
      final h = HeadIndexHost();
      final c = headIndexController(r, h, workfile);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ImportedHeadIndexPanel(
                root: '/project',
                records: r,
                workfile: workfile,
                controller: c,
              ),
            ),
          ),
        ),
      );
      expect(h.calls, 0);
      await tester.tap(find.text('Review declared-object read'));
      await tester.pumpAndSettle();
      expect(find.text('Read declared HEAD object facts?'), findsOneWidget);
      expect(h.calls, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.calls, 0);
      await tester.tap(find.text('Review declared-object read'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read declared objects'));
      await tester.pumpAndSettle();
      expect(h.calls, 1);
      expect(find.text('Completed declared-object read'), findsOneWidget);
      expect(find.text('Working bytes: match observed tree'), findsOneWidget);
      expect(
        find.text('Executable bit: matches observed tree'),
        findsOneWidget,
      );
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      await tester.pumpWidget(const SizedBox());
      closeWorkfile(workfile);
    },
  );
  testWidgets('changed runtime while consent open prevents any read', (
    tester,
  ) async {
    final r = await baseline.indexRecords();
    final workfile = await readyWorkfile(r);
    final h = HeadIndexHost();
    final c = headIndexController(r, h, workfile);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ImportedHeadIndexPanel(
              root: '/project',
              records: r,
              workfile: workfile,
              controller: c,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Review declared-object read'));
    await tester.pumpAndSettle();
    r.values['studio.runtimeSetup.v1'] = 'changed';
    await tester.tap(find.text('Read declared objects'));
    await tester.pumpAndSettle();
    expect(h.calls, 0);
    expect(c.observationCurrent, false);
    expect(
      find.textContaining('Previous evidence is historical'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    closeWorkfile(workfile);
  });
  testWidgets('delayed read exposes Stop and never publishes late completion', (
    tester,
  ) async {
    final r = await baseline.indexRecords();
    final workfile = await readyWorkfile(r);
    final h = HeadIndexHost()..gate = Completer();
    final c = headIndexController(r, h, workfile);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ImportedHeadIndexPanel(
              root: '/project',
              records: r,
              workfile: workfile,
              controller: c,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Review declared-object read'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read declared objects'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.calls, 1);
    expect(find.text('Stop declared-object read'), findsOneWidget);
    await tester.tap(find.text('Stop declared-object read'));
    await tester.pumpAndSettle();
    expect(c.observation, null);
    expect(c.busy, false);
    await tester.pumpWidget(const SizedBox());
    closeWorkfile(workfile);
  });
  testWidgets('refused retry retains previous dated comparison as historical', (
    tester,
  ) async {
    final r = await baseline.indexRecords();
    final workfile = await readyWorkfile(r);
    final h = HeadIndexHost();
    final c = headIndexController(r, h, workfile);
    var request = await c.prepare();
    await c.inspect(request!, confirmed: true);
    request = await c.prepare();
    h.gate = Completer();
    final pending = c.inspect(request!, confirmed: true);
    await tester.pump();
    h.gate!.complete(
      ImportedHeadIndexObservation.fromJson(
        jsonEncode({
          ...headIndexObservationData(request),
          'status': 'refused',
          'reason': 'changed',
          'acquisition': null,
          'head_form': null,
          'declared_ref': null,
          'head_oid': null,
          'tree_oid': null,
          'index_sha256': null,
          'object_count': 0,
          'object_bytes': 0,
          'files': <Object>[],
        }),
        request: request,
      ),
    );
    await pending;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ImportedHeadIndexPanel(
              root: '/project',
              records: r,
              workfile: workfile,
              controller: c,
            ),
          ),
        ),
      ),
    );
    expect(
      find.text('Previous declared-object read — historical'),
      findsOneWidget,
    );
    expect(
      find.textContaining('No declared-object joins were accepted'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    closeWorkfile(workfile);
  });
  testWidgets(
    'unsupported narrow scaled panel remains readable with action disabled',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final r = await baseline.indexRecords();
      final workfile = await readyWorkfile(r);
      final h = HeadIndexHost()..available = false;
      final c = headIndexController(r, h, workfile);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ImportedHeadIndexPanel(
                root: '/project',
                records: r,
                workfile: workfile,
                controller: c,
              ),
            ),
          ),
        ),
      );
      expect(
        find.text('Declared-object reading is unavailable on this platform.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(
                OutlinedButton,
                'Review declared-object read',
              ),
            )
            .onPressed,
        null,
      );
      expect(tester.takeException(), null);
      expect(h.calls, 0);
      await tester.pumpWidget(const SizedBox());
      closeWorkfile(workfile);
    },
  );
  testWidgets('observed narrow scaled fingerprints and paths do not overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final r = await baseline.indexRecords();
    final workfile = await readyWorkfile(r);
    final h = HeadIndexHost();
    final c = headIndexController(r, h, workfile);
    final request = await c.prepare();
    await c.inspect(request!, confirmed: true);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ImportedHeadIndexPanel(
              root: '/project',
              records: r,
              workfile: workfile,
              controller: c,
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('Declared-object fingerprints'));
    await tester.tap(find.text('Declared-object fingerprints'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Declared HEAD ID:'), findsOneWidget);
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox());
    closeWorkfile(workfile);
  });
}
