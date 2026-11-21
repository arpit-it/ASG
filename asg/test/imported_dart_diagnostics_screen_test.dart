// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/views/imported_dart_diagnostics_screen.dart';
import 'package:asg/services/imported_commit_edit_comparison_store.dart';

import 'imported_commit_edit_comparison_controller_test.dart'
    show comparisonRecords;
import 'imported_dart_diagnostics_controller_test.dart'
    show DiagnosticHost, diagnosticController;

Future<void> reveal(WidgetTester t, Finder finder) async {
  await t.scrollUntilVisible(
    finder,
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await t.ensureVisible(finder);
  await t.pump();
}

void main() {
  testWidgets(
    'SDK review is explicit and cancelled consent cannot dispatch; confirmed consent produces isolated evidence',
    (t) async {
      final r = await comparisonRecords(), h = DiagnosticHost();
      final c = diagnosticController(r, h);
      await t.pumpWidget(
        MaterialApp(home: ImportedDartDiagnosticsScreen(controller: c)),
      );
      await t.pumpAndSettle();
      expect(h.reviews, 0);
      expect(h.calls, 0);
      await reveal(t, find.byType(TextField));
      await t.enterText(find.byType(TextField), '/trusted/sdk');
      await t.pump();
      await t.tap(find.text('Review SDK identity'));
      await t.pumpAndSettle();
      expect(h.reviews, 1);
      expect(h.calls, 0);
      await reveal(t, find.text('Review diagnostics consent'));
      await t.tap(find.text('Review diagnostics consent'));
      await t.pumpAndSettle();
      expect(find.text('Run isolated file diagnostics?'), findsOneWidget);
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(h.calls, 0);
      await t.tap(find.text('Review diagnostics consent'));
      await t.pumpAndSettle();
      await t.tap(find.text('Run isolated diagnostics'));
      await t.pumpAndSettle();
      expect(h.calls, 1);
      expect(c.resultCurrent, true);
      await reveal(t, find.text('Completed isolated diagnostics: clean'));
      expect(
        find.text(
          'No findings in the isolated file. The project remains unverified.',
        ),
        findsOneWidget,
      );
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pump();
    },
  );
  testWidgets(
    'edited SDK path discards review and stale dialog consent cannot start a worker',
    (t) async {
      final r = await comparisonRecords(), h = DiagnosticHost();
      final c = diagnosticController(r, h);
      await t.pumpWidget(
        MaterialApp(home: ImportedDartDiagnosticsScreen(controller: c)),
      );
      await t.pumpAndSettle();
      await reveal(t, find.byType(TextField));
      await t.enterText(find.byType(TextField), '/trusted/sdk');
      await t.tap(find.text('Review SDK identity'));
      await t.pumpAndSettle();
      expect(c.request, isNotNull);
      await t.enterText(find.byType(TextField), '/trusted/other-sdk');
      await t.pump();
      expect(c.request, isNull);
      await t.tap(find.text('Review SDK identity'));
      await t.pumpAndSettle();
      await t.tap(find.text('Review diagnostics consent'));
      await t.pumpAndSettle();
      r.values[ImportedCommitEditComparisonStore.runtimeKey] = 'changed';
      await t.tap(find.text('Run isolated diagnostics'));
      await t.pumpAndSettle();
      expect(h.calls, 0);
      expect(c.stale, true);
      await t.pumpWidget(const SizedBox());
      await t.pump();
    },
  );
  testWidgets(
    'unsupported view retains identity and never offers enabled native actions at narrow large text',
    (t) async {
      t.view.physicalSize = const Size(390, 844);
      t.view.devicePixelRatio = 1;
      addTearDown(t.view.resetPhysicalSize);
      addTearDown(t.view.resetDevicePixelRatio);
      final r = await comparisonRecords(),
          h = DiagnosticHost()..available = false;
      final c = diagnosticController(r, h);
      await t.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ImportedDartDiagnosticsScreen(controller: c),
        ),
      );
      await t.pumpAndSettle();
      await reveal(
        t,
        find.text(
          'Native diagnostics are unavailable on this platform. Saved histories remain readable.',
        ),
      );
      expect(c.canReview, false);
      expect(h.calls, 0);
      expect(h.reviews, 0);
      expect(t.takeException(), isNull);
      await t.pumpWidget(const SizedBox());
      await t.pump();
    },
  );
  testWidgets(
    'Stop during SDK review remains available and cannot reveal late consent',
    (t) async {
      final r = await comparisonRecords(),
          h = DiagnosticHost()..reviewGate = Completer();
      final c = diagnosticController(r, h);
      await t.pumpWidget(
        MaterialApp(home: ImportedDartDiagnosticsScreen(controller: c)),
      );
      await t.pumpAndSettle();
      await reveal(t, find.byType(TextField));
      await t.enterText(find.byType(TextField), '/trusted/sdk');
      await t.tap(find.text('Review SDK identity'));
      await t.pump();
      await t.pump();
      await reveal(t, find.text('Stop diagnostics'));
      await t.tap(find.text('Stop diagnostics'));
      await t.pumpAndSettle();
      expect(h.calls, 0);
      expect(c.request, isNull);
      expect(c.busy, false);
      await t.pumpWidget(const SizedBox());
      await t.pump();
    },
  );
}
