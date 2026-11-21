// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/views/imported_commit_copy_recheck_screen.dart';
import 'package:asg/views/imported_project_workspace.dart';
import 'package:asg/views/imported_commit_copy_recheck_screen.dart' as view;

import 'imported_commit_copy_recheck_controller_test.dart' as fixture;
import 'imported_commit_copy_screen_test.dart' show reveal;
import 'imported_plan_test.dart' show finding;

void main() {
  testWidgets(
    'review opens with zero effects; explicit read publishes dated result only',
    (tester) async {
      final r = await fixture.recheckRecords(), h = fixture.RecheckHost();
      final c = fixture.recheckController(r, h);
      await tester.pumpWidget(
        MaterialApp(home: ImportedCommitCopyRecheckScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      expect(h.calls, 0);
      await reveal(tester, find.text('Recheck current copy'));
      await tester.tap(find.text('Recheck current copy'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Copy observation: matching'));
      expect(find.text('Copy observation: matching'), findsOneWidget);
      expect(h.calls, 1);
      expect(r.updatesSeen.every((v) => v.isEmpty), true);
    },
  );
  testWidgets('busy read exposes Stop and retains historical observation', (
    tester,
  ) async {
    final r = await fixture.recheckRecords(), h = fixture.RecheckHost();
    final c = fixture.recheckController(r, h);
    await tester.pumpWidget(
      MaterialApp(home: ImportedCommitCopyRecheckScreen(controller: c)),
    );
    await tester.pumpAndSettle();
    await c.recheck(c.request!);
    await c.load();
    h.gate = Completer();
    final pending = c.recheck(c.request!);
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Stop recheck'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Stop recheck'));
    await pending;
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Previous observation — historical'));
    expect(h.calls, 2);
  });
  testWidgets('narrow enlarged read-only disclosure remains scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final r = await fixture.recheckRecords(), h = fixture.RecheckHost();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: ImportedCommitCopyRecheckScreen(
          controller: fixture.recheckController(r, h),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.text('Recheck current copy'));
    expect(tester.takeException(), isNull);
    expect(h.calls, 0);
  });
  testWidgets(
    'workspace saved-copy history opens pinned recheck without dispatch',
    (tester) async {
      final r = await fixture.recheckRecords();
      await tester.pumpWidget(
        MaterialApp(
          home: ImportedProjectWorkspace(inspection: finding(), records: r),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Open baseline-copy history'));
      await tester.tap(find.text('Open baseline-copy history'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Review current copy recheck'));
      await tester.tap(find.text('Review current copy recheck'));
      await tester.pumpAndSettle();
      final screen = tester.widget<view.ImportedCommitCopyRecheckScreen>(
        find.byType(view.ImportedCommitCopyRecheckScreen),
      );
      expect(screen.controller.expectedHistoryDigest, isNotNull);
      expect(screen.controller.result, isNull);
      expect(r.updatesSeen.every((v) => v.isEmpty), true);
    },
  );
}
