// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/views/imported_commit_edit_comparison_screen.dart';
import 'package:asg/views/imported_project_workspace.dart';
import 'package:asg/views/imported_commit_edit_comparison_screen.dart' as view;

import 'imported_commit_edit_comparison_controller_test.dart' as fixture;
import 'imported_commit_copy_screen_test.dart' show reveal;
import 'imported_plan_test.dart' show finding;

void main() {
  testWidgets(
    'review opens with zero effects; explicit read publishes dated result only',
    (tester) async {
      final r = await fixture.comparisonRecords(), h = fixture.ComparisonHost();
      final c = fixture.comparisonController(r, h);
      await tester.pumpWidget(
        MaterialApp(home: ImportedCommitEditComparisonScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      expect(h.calls, 0);
      await reveal(tester, find.text('Compare current copies'));
      await tester.tap(find.text('Compare current copies'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Completed read: matching'));
      expect(find.text('Completed read: matching'), findsOneWidget);
      expect(h.calls, 1);
      expect(r.updatesSeen.every((v) => v.isEmpty), true);
    },
  );
  testWidgets('busy read exposes Stop and retains historical observation', (
    tester,
  ) async {
    final r = await fixture.comparisonRecords(), h = fixture.ComparisonHost();
    final c = fixture.comparisonController(r, h);
    await tester.pumpWidget(
      MaterialApp(home: ImportedCommitEditComparisonScreen(controller: c)),
    );
    await tester.pumpAndSettle();
    await c.compare(c.request!);
    await c.load();
    h.gate = Completer();
    final pending = c.compare(c.request!);
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Stop comparison'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Stop comparison'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Stop comparison'));
    await pending;
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Previous read — historical: matching'));
    expect(h.calls, 2);
  });
  testWidgets('narrow enlarged read-only disclosure remains scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final r = await fixture.comparisonRecords(), h = fixture.ComparisonHost();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: ImportedCommitEditComparisonScreen(
          controller: fixture.comparisonController(r, h),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Compare current copies'));
    expect(tester.takeException(), isNull);
    expect(h.calls, 0);
  });
  testWidgets(
    'workspace saved-copy history opens pinned recheck without dispatch',
    (tester) async {
      final r = await fixture.comparisonRecords();
      await tester.pumpWidget(
        MaterialApp(
          home: ImportedProjectWorkspace(inspection: finding(), records: r),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Open proposed-copy history'));
      await tester.tap(find.text('Open proposed-copy history'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Compare saved proposed copy'));
      await tester.tap(find.text('Compare saved proposed copy'));
      await tester.pumpAndSettle();
      final screen = tester.widget<view.ImportedCommitEditComparisonScreen>(
        find.byType(view.ImportedCommitEditComparisonScreen),
      );
      expect(screen.controller.expectedEditHistoryDigest, isNotNull);
      expect(screen.controller.result, isNull);
      expect(r.updatesSeen.every((v) => v.isEmpty), true);
    },
  );
}
