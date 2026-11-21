// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:asg/services/imported_commit_copy_store.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/services/imported_commit_proposal_store.dart';
import 'package:asg/views/imported_commit_copy_screen.dart';
import 'package:asg/views/imported_project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_commit_copy_controller_test.dart' as fixture;
import 'imported_plan_test.dart' show finding;

Future<void> reveal(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    200,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> review(WidgetTester tester) async {
  await reveal(tester, find.byType(TextField));
  await tester.enterText(find.byType(TextField), '/copies');
  await reveal(tester, find.text('Review original copy'));
  await tester.tap(find.text('Review original copy'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'review and Cancel do not dispatch; explicit consent confirms original copy',
    (tester) async {
      final r = await fixture.copyRecords(), host = fixture.CopyHost();
      final c = fixture.copyController(r, host);
      await tester.pumpWidget(
        MaterialApp(home: ImportedCommitCopyScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      await review(tester);
      expect(host.calls, 0);
      await reveal(tester, find.text('Prepare original copy'));
      await tester.tap(find.text('Prepare original copy'));
      await tester.pumpAndSettle();
      expect(find.text('Create original commit copy?'), findsOneWidget);
      expect(
        find.textContaining('proposed replacement is NOT applied'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(host.calls, 0);
      expect(r.values[ImportedCommitCopyStore.key('/project')], isNull);
      await tester.tap(find.text('Prepare original copy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create copy'));
      await tester.pumpAndSettle();
      expect(host.calls, 1);
      expect(c.history!.lastPrepared, isNotNull);
      await reveal(
        tester,
        find.text('Last durably confirmed original copy — historical'),
      );
      expect(find.textContaining('Whole-copy fingerprint:'), findsOneWidget);
    },
  );
  testWidgets(
    'saved input changing while consent is open prevents helper startup',
    (tester) async {
      final r = await fixture.copyRecords(), host = fixture.CopyHost();
      final c = fixture.copyController(r, host);
      await tester.pumpWidget(
        MaterialApp(home: ImportedCommitCopyScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      await review(tester);
      await reveal(tester, find.text('Prepare original copy'));
      await tester.tap(find.text('Prepare original copy'));
      await tester.pumpAndSettle();
      r.values.remove(ImportedPlanStore.key('/project'));
      await tester.tap(find.text('Create copy'));
      await tester.pumpAndSettle();
      expect(host.calls, 0);
      expect(c.error, isNotNull);
      expect(r.values[ImportedCommitCopyStore.key('/project')], isNull);
    },
  );
  testWidgets('replacement controller cannot inherit an open copy consent', (
    tester,
  ) async {
    final r = await fixture.copyRecords(), host = fixture.CopyHost();
    final old = fixture.copyController(r, host);
    await tester.pumpWidget(
      MaterialApp(home: ImportedCommitCopyScreen(controller: old)),
    );
    await tester.pumpAndSettle();
    await review(tester);
    await reveal(tester, find.text('Prepare original copy'));
    await tester.tap(find.text('Prepare original copy'));
    await tester.pumpAndSettle();
    final nextHost = fixture.CopyHost();
    final next = fixture.copyController(r, nextHost);
    await tester.pumpWidget(
      MaterialApp(home: ImportedCommitCopyScreen(controller: next)),
    );
    await tester.pumpAndSettle();
    expect(old.isDisposed, true);
    await tester.tap(find.text('Create copy'));
    await tester.pumpAndSettle();
    expect(host.calls, 0);
    expect(nextHost.calls, 0);
    expect(next.draft, isNull);
  });
  testWidgets(
    'pending restart requires checked inspection and never replays a helper',
    (tester) async {
      final r = await fixture.copyRecords(), host = fixture.CopyHost();
      host.fail = true;
      final original = fixture.copyController(r, host);
      await original.load();
      await original.review('/copies');
      await original.prepare(original.draft!);
      original.dispose();
      final freshHost = fixture.CopyHost();
      final fresh = fixture.copyController(r, freshHost);
      await tester.pumpWidget(
        MaterialApp(home: ImportedCommitCopyScreen(controller: fresh)),
      );
      await tester.pumpAndSettle();
      expect(fresh.canReview, false);
      expect(freshHost.calls, 0);
      await reveal(tester, find.text('Confirm recovery inspection'));
      await tester.tap(find.text('Confirm recovery inspection'));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Acknowledge inspection'),
            )
            .onPressed,
        isNull,
      );
      await tester.ensureVisible(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Acknowledge inspection'));
      await tester.pumpAndSettle();
      expect(fresh.history!.needsRecovery, false);
      expect(fresh.history!.lastPrepared, isNull);
      expect(freshHost.calls, 0);
      expect(fresh.canReview, false);
    },
  );
  testWidgets('narrow enlarged review and consent scroll without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final r = await fixture.copyRecords(), host = fixture.CopyHost();
    final c = fixture.copyController(r, host);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: ImportedCommitCopyScreen(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await review(tester);
    await reveal(tester, find.text('Prepare original copy'));
    await tester.tap(find.text('Prepare original copy'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(host.calls, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'saved committed proposal opens pinned original-copy review without dispatch',
    (tester) async {
      final r = await fixture.copyRecords();
      final saved = ImportedCommitProposalStore(r).history('/project').record!;
      await tester.pumpWidget(
        MaterialApp(
          home: ImportedProjectWorkspace(inspection: finding(), records: r),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Open saved committed-source comparison'));
      await tester.tap(find.text('Open saved committed-source comparison'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Prepare original commit copy'));
      await tester.tap(find.text('Prepare original commit copy'));
      await tester.pumpAndSettle();
      final screen = tester.widget<ImportedCommitCopyScreen>(
        find.byType(ImportedCommitCopyScreen),
      );
      expect(screen.controller.expectedHistoryDigest, saved.digest);
      expect(screen.controller.currentProposal!.digest, saved.digest);
      expect(screen.controller.host.lastObservation, isNull);
      expect(r.values[ImportedCommitCopyStore.key('/project')], isNull);
      expect(find.text('Prepare immutable baseline copy'), findsOneWidget);
      expect(r.updatesSeen, everyElement(isEmpty));
    },
  );
  testWidgets(
    'workspace history opens read-only without current proposal or source access',
    (tester) async {
      final r = await fixture.copyRecords();
      r.values.clear();
      await tester.pumpWidget(
        MaterialApp(
          home: ImportedProjectWorkspace(inspection: finding(), records: r),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Open baseline-copy history'));
      await tester.tap(find.text('Open baseline-copy history'));
      await tester.pumpAndSettle();
      expect(find.text('Saved baseline-copy history'), findsOneWidget);
      expect(
        find.text('No saved baseline-copy attempts for this folder.'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(r.values, isEmpty);
      expect(r.updatesSeen, everyElement(isEmpty));
    },
  );
}
