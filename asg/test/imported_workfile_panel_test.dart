// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_workfile_comparison.dart';
import 'package:asg/views/imported_workfile_panel.dart';

import 'imported_index_controller_test.dart' as baseline;
import 'imported_workfile_controller_test.dart';
import 'imported_workfile_comparison_test.dart' show workfileObservationData;

void main() {
  testWidgets(
    'startup and cancelled consent never read; confirmed selection shows separate comparisons',
    (tester) async {
      final r = await baseline.indexRecords();
      final index = await readyIndex(r);
      final h = WorkfileHost();
      final c = workfileController(r, h, index);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ImportedWorkfilePanel(
                root: '/project',
                records: r,
                index: index,
                controller: c,
              ),
            ),
          ),
        ),
      );
      expect(h.calls, 0);
      await tester.enterText(find.byType(TextField), 'lib/main.dart');
      await tester.tap(find.text('Review selected-file read'));
      await tester.pumpAndSettle();
      expect(find.text('Compare selected working files?'), findsOneWidget);
      expect(h.calls, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.calls, 0);
      await tester.tap(find.text('Review selected-file read'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Compare files'));
      await tester.pumpAndSettle();
      expect(h.calls, 1);
      expect(find.text('Completed selected-file comparison'), findsOneWidget);
      expect(find.text('Raw bytes: match index declaration'), findsOneWidget);
      expect(
        find.text('Executable bit: matches index declaration'),
        findsOneWidget,
      );
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      await tester.pumpWidget(const SizedBox());
      index.dispose();
    },
  );
  testWidgets('changed runtime while consent open prevents any read', (
    tester,
  ) async {
    final r = await baseline.indexRecords();
    final index = await readyIndex(r);
    final h = WorkfileHost();
    final c = workfileController(r, h, index);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ImportedWorkfilePanel(
              root: '/project',
              records: r,
              index: index,
              controller: c,
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'lib/main.dart');
    await tester.tap(find.text('Review selected-file read'));
    await tester.pumpAndSettle();
    r.values['studio.runtimeSetup.v1'] = 'changed';
    await tester.tap(find.text('Compare files'));
    await tester.pumpAndSettle();
    expect(h.calls, 0);
    expect(c.observationCurrent, false);
    expect(
      find.textContaining('Previous evidence is historical'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    index.dispose();
  });
  testWidgets('delayed read exposes Stop and never publishes late completion', (
    tester,
  ) async {
    final r = await baseline.indexRecords();
    final index = await readyIndex(r);
    final h = WorkfileHost()..gate = Completer();
    final c = workfileController(r, h, index);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ImportedWorkfilePanel(
              root: '/project',
              records: r,
              index: index,
              controller: c,
            ),
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), 'lib/main.dart');
    await tester.tap(find.text('Review selected-file read'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compare files'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(h.calls, 1);
    expect(find.text('Stop file comparison'), findsOneWidget);
    await tester.tap(find.text('Stop file comparison'));
    await tester.pumpAndSettle();
    expect(c.observation, null);
    expect(c.busy, false);
    await tester.pumpWidget(const SizedBox());
    index.dispose();
  });
  testWidgets('refused retry retains previous dated comparison as historical', (
    tester,
  ) async {
    final r = await baseline.indexRecords();
    final index = await readyIndex(r);
    final h = WorkfileHost();
    final c = workfileController(r, h, index);
    var request = await c.prepare(['lib/main.dart']);
    await c.inspect(request!, confirmed: true);
    request = await c.prepare(['lib/main.dart']);
    h.gate = Completer();
    final pending = c.inspect(request!, confirmed: true);
    await tester.pump();
    h.gate!.complete(
      ImportedWorkfileObservation.fromJson(
        jsonEncode({
          ...workfileObservationData(request),
          'status': 'refused',
          'reason': 'changed',
          'index_sha256': null,
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
            child: ImportedWorkfilePanel(
              root: '/project',
              records: r,
              index: index,
              controller: c,
            ),
          ),
        ),
      ),
    );
    expect(
      find.text('Previous selected-file comparison — historical'),
      findsOneWidget,
    );
    expect(
      find.textContaining('No selected-file comparisons were accepted'),
      findsOneWidget,
    );
    await tester.pumpWidget(const SizedBox());
    index.dispose();
  });
  testWidgets(
    'unsupported narrow scaled panel remains readable with action disabled',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final r = await baseline.indexRecords();
      final index = await readyIndex(r);
      final h = WorkfileHost()..available = false;
      final c = workfileController(r, h, index);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ImportedWorkfilePanel(
                root: '/project',
                records: r,
                index: index,
                controller: c,
              ),
            ),
          ),
        ),
      );
      expect(
        find.text('Selected-file comparison is unavailable on this platform.'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Review selected-file read'),
            )
            .onPressed,
        null,
      );
      expect(tester.takeException(), null);
      expect(h.calls, 0);
      await tester.pumpWidget(const SizedBox());
      index.dispose();
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
    final index = await readyIndex(r);
    final h = WorkfileHost();
    final c = workfileController(r, h, index);
    final request = await c.prepare(['lib/main.dart']);
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
            child: ImportedWorkfilePanel(
              root: '/project',
              records: r,
              index: index,
              controller: c,
            ),
          ),
        ),
      ),
    );
    await tester.ensureVisible(find.text('Selected-file fingerprints'));
    await tester.tap(find.text('Selected-file fingerprints'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Working-file SHA-256:'), findsOneWidget);
    expect(tester.takeException(), null);
    await tester.pumpWidget(const SizedBox());
    index.dispose();
  });
}
