// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/views/imported_commit_comparison_screen.dart';
import 'package:asg/services/imported_plan_store.dart';

import 'imported_commit_comparison_controller_test.dart'
    show CommitHost, baselineRecords, commitController;
import 'imported_source_baseline_test.dart' show baselineSaved;

void main() {
  testWidgets(
    'no automatic read; explicit consent cancel and confirm preserve saved records',
    (tester) async {
      final saved = baselineSaved(), host = CommitHost(baselineSaved());
      final r = await baselineRecords(saved),
          before = Map<String, String>.of(
            (await baselineRecords(saved)).values,
          );
      final c = commitController(r, host);
      await tester.pumpWidget(
        MaterialApp(home: ImportedCommitComparisonScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      expect(host.reads, 0);
      await tester.tap(find.text('Compare with commit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Read selected commit content?'), findsOneWidget);
      expect(find.text('test/peer.dart'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(host.reads, 0);
      await tester.tap(find.text('Compare with commit'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Read commit content'));
      await tester.pumpAndSettle();
      expect(c.comparison!.matched, true);
      expect(host.reads, 1);
      expect(r.values, before);
      expect(r.updatesSeen, everyElement(isEmpty));
    },
  );
  testWidgets('changed inputs during read consent prevent source dispatch', (
    tester,
  ) async {
    final saved = baselineSaved(), host = CommitHost(baselineSaved());
    final r = await baselineRecords(saved);
    final owner = commitController(r, host);
    await tester.pumpWidget(
      MaterialApp(home: ImportedCommitComparisonScreen(controller: owner)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compare with commit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    r.values[ImportedPlanStore.key(saved.root)] = 'changed';
    await tester.tap(find.text('Read commit content'));
    await tester.pumpAndSettle();
    expect(host.reads, 0);
    expect(owner.comparison, isNull);
    expect(owner.error, isNotNull);
  });
  testWidgets('replaced controller cannot inherit old read consent', (
    tester,
  ) async {
    final saved = baselineSaved(),
        firstHost = CommitHost(baselineSaved()),
        secondHost = CommitHost(baselineSaved());
    final r = await baselineRecords(saved);
    final original = commitController(r, firstHost),
        replacement = commitController(r, secondHost);
    await tester.pumpWidget(
      MaterialApp(home: ImportedCommitComparisonScreen(controller: original)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Compare with commit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(
      MaterialApp(
        home: ImportedCommitComparisonScreen(controller: replacement),
      ),
    );
    await tester.pumpAndSettle();
    expect(original.isDisposed, true);
    await tester.tap(find.text('Read commit content'));
    await tester.pumpAndSettle();
    expect(firstHost.reads, 0);
    expect(secondHost.reads, 0);
    expect(replacement.comparison, isNull);
  });
  testWidgets(
    'unsupported host does not offer a read or lose historical context',
    (tester) async {
      final saved = baselineSaved(),
          host = CommitHost(baselineSaved())..supported = false;
      final c = commitController(await baselineRecords(saved), host);
      await tester.pumpWidget(
        MaterialApp(home: ImportedCommitComparisonScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Immutable commit reads are unavailable'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Compare with commit'),
            )
            .onPressed,
        isNull,
      );
      expect(host.reads, 0);
    },
  );
  testWidgets('narrow large-text read consent and result remain scrollable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final saved = baselineSaved(), host = CommitHost(baselineSaved());
    final c = commitController(await baselineRecords(saved), host);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: ImportedCommitComparisonScreen(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Compare with commit'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Compare with commit'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Read commit content'));
    await tester.pumpAndSettle();
    expect(c.comparison!.matched, true);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'full commit input is required and never resolves a branch automatically',
    (tester) async {
      final saved = baselineSaved(), host = CommitHost(baselineSaved());
      final c = commitController(await baselineRecords(saved), host)
        ..setCommit('');
      await tester.pumpWidget(
        MaterialApp(home: ImportedCommitComparisonScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      final button = find.widgetWithText(FilledButton, 'Compare with commit');
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.enterText(find.byType(TextField), 'HEAD');
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      expect(host.reads, 0);
      await tester.enterText(find.byType(TextField), 'a' * 40);
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      expect(host.reads, 0);
    },
  );
}
