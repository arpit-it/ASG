// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/views/imported_source_baseline_screen.dart';
import 'package:asg/services/imported_plan_store.dart';

import 'imported_source_baseline_controller_test.dart'
    show BaselineHost, baselineRecords, baselineController;
import 'imported_source_baseline_test.dart' show baselineSaved;

void main() {
  testWidgets(
    'no automatic read; explicit consent cancel and confirm preserve saved records',
    (tester) async {
      final saved = baselineSaved(), host = BaselineHost(baselineSaved());
      final r = await baselineRecords(saved),
          before = Map<String, String>.of(
            (await baselineRecords(saved)).values,
          );
      final c = baselineController(r, host);
      await tester.pumpWidget(
        MaterialApp(home: ImportedSourceBaselineScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      expect(host.reads, 0);
      await tester.tap(find.text('Recheck captured files'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('Read captured files again?'), findsOneWidget);
      expect(find.text('test/peer.dart'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(host.reads, 0);
      await tester.tap(find.text('Recheck captured files'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('Read selected files'));
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
    final saved = baselineSaved(), host = BaselineHost(baselineSaved());
    final r = await baselineRecords(saved);
    final owner = baselineController(r, host);
    await tester.pumpWidget(
      MaterialApp(home: ImportedSourceBaselineScreen(controller: owner)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recheck captured files'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    r.values[ImportedPlanStore.key(saved.root)] = 'changed';
    await tester.tap(find.text('Read selected files'));
    await tester.pumpAndSettle();
    expect(host.reads, 0);
    expect(owner.comparison, isNull);
    expect(owner.error, isNotNull);
  });
  testWidgets('replaced controller cannot inherit old read consent', (
    tester,
  ) async {
    final saved = baselineSaved(),
        firstHost = BaselineHost(baselineSaved()),
        secondHost = BaselineHost(baselineSaved());
    final r = await baselineRecords(saved);
    final original = baselineController(r, firstHost),
        replacement = baselineController(r, secondHost);
    await tester.pumpWidget(
      MaterialApp(home: ImportedSourceBaselineScreen(controller: original)),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Recheck captured files'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pumpWidget(
      MaterialApp(home: ImportedSourceBaselineScreen(controller: replacement)),
    );
    await tester.pumpAndSettle();
    expect(original.isDisposed, true);
    await tester.tap(find.text('Read selected files'));
    await tester.pumpAndSettle();
    expect(firstHost.reads, 0);
    expect(secondHost.reads, 0);
    expect(replacement.comparison, isNull);
  });
  testWidgets(
    'unsupported host does not offer a read or lose historical context',
    (tester) async {
      final saved = baselineSaved(),
          host = BaselineHost(baselineSaved())..supported = false;
      final c = baselineController(await baselineRecords(saved), host);
      await tester.pumpWidget(
        MaterialApp(home: ImportedSourceBaselineScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Contained source reads are unavailable'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Recheck captured files'),
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
    final saved = baselineSaved(), host = BaselineHost(baselineSaved());
    final c = baselineController(await baselineRecords(saved), host);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: ImportedSourceBaselineScreen(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('Recheck captured files'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Recheck captured files'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Read selected files'));
    await tester.pumpAndSettle();
    expect(c.comparison!.matched, true);
    expect(tester.takeException(), isNull);
  });
}
