// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/views/imported_commit_edit_screen.dart';
import 'package:asg/views/imported_project_workspace.dart';
import 'package:asg/services/imported_commit_edit_store.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/models/runtime_setup.dart';

import 'imported_commit_edit_controller_test.dart' as fixture;
import 'imported_commit_copy_recheck_controller_test.dart' show RecheckHost;
import 'imported_commit_copy_screen_test.dart' show reveal;
import 'imported_plan_test.dart' show finding;

Future<void> review(WidgetTester tester) async {
  await reveal(tester, find.byType(TextField));
  await tester.enterText(find.byType(TextField), '/output');
  await reveal(tester, find.text('Review proposed copy'));
  await tester.tap(find.text('Review proposed copy'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'fresh read and Cancel cannot write; explicit consent creates isolated proposed journal',
    (tester) async {
      final r = await fixture.editRecords(),
          h = fixture.EditHost(),
          reader = RecheckHost();
      final c = fixture.editController(r, h, reader);
      await tester.pumpWidget(
        MaterialApp(home: ImportedCommitEditScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      await review(tester);
      expect(reader.calls, 1);
      expect(h.calls, 0);
      expect(r.values[ImportedCommitEditStore.key('/project')], isNull);
      await reveal(tester, find.text('Prepare proposed copy'));
      await tester.tap(find.text('Prepare proposed copy'));
      await tester.pumpAndSettle();
      expect(find.text('Create isolated proposed copy?'), findsOneWidget);
      expect(
        find.textContaining('exactly this one reviewed replacement'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.calls, 0);
      await tester.tap(find.text('Prepare proposed copy'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create proposed copy'));
      await tester.pumpAndSettle();
      expect(h.calls, 1);
      expect(c.history!.lastPrepared, isNotNull);
    },
  );
  testWidgets('changed runtime while consent is open cannot retarget writing', (
    tester,
  ) async {
    final r = await fixture.editRecords(), h = fixture.EditHost();
    final c = fixture.editController(r, h, RecheckHost());
    await tester.pumpWidget(
      MaterialApp(home: ImportedCommitEditScreen(controller: c)),
    );
    await tester.pumpAndSettle();
    await review(tester);
    await reveal(tester, find.text('Prepare proposed copy'));
    await tester.tap(find.text('Prepare proposed copy'));
    await tester.pumpAndSettle();
    await RuntimeSetupStore(r)
        .save(const RuntimeSetup(python: '/changed/python'));
    await tester.tap(find.text('Create proposed copy'));
    await tester.pumpAndSettle();
    expect(h.calls, 0);
    expect(r.values[ImportedCommitEditStore.key('/project')], isNull);
  });
  testWidgets('replaced controller cannot inherit another open consent', (
    tester,
  ) async {
    final r = await fixture.editRecords(),
        oldHost = fixture.EditHost(),
        newHost = fixture.EditHost();
    final old = fixture.editController(r, oldHost, RecheckHost()),
        next = fixture.editController(r, newHost, RecheckHost());
    final current = ValueNotifier(old);
    addTearDown(current.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder(
          valueListenable: current,
          builder: (context, value, _) =>
              ImportedCommitEditScreen(controller: value),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await review(tester);
    await reveal(tester, find.text('Prepare proposed copy'));
    await tester.tap(find.text('Prepare proposed copy'));
    await tester.pumpAndSettle();
    current.value = next;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create proposed copy'));
    await tester.pumpAndSettle();
    expect(old.isDisposed, true);
    expect(oldHost.calls, 0);
    expect(newHost.calls, 0);
  });
  testWidgets('Stop review leaves no pending output and no writer call', (
    tester,
  ) async {
    final r = await fixture.editRecords(),
        h = fixture.EditHost(),
        reader = RecheckHost()..gate = Completer();
    final c = fixture.editController(r, h, reader);
    await tester.pumpWidget(
      MaterialApp(home: ImportedCommitEditScreen(controller: c)),
    );
    await tester.pumpAndSettle();
    await reveal(tester, find.byType(TextField));
    await tester.enterText(find.byType(TextField), '/output');
    await tester.tap(find.text('Review proposed copy'));
    await tester.pump();
    await tester.scrollUntilVisible(
      find.text('Stop review'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Stop review'));
    await tester.pumpAndSettle();
    expect(c.draft, isNull);
    expect(h.calls, 0);
    expect(r.values[ImportedCommitEditStore.key('/project')], isNull);
  });
  testWidgets(
    'narrow enlarged diff review and confirmation scroll without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final r = await fixture.editRecords();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ImportedCommitEditScreen(
            controller: fixture.editController(
              r,
              fixture.EditHost(),
              RecheckHost(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await review(tester);
      await reveal(tester, find.text('Prepare proposed copy'));
      await tester.tap(find.text('Prepare proposed copy'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
    },
  );
  testWidgets(
    'workspace original-copy history opens pinned proposed review with zero writes',
    (tester) async {
      final r = await fixture.editRecords();
      await tester.pumpWidget(
        MaterialApp(
          home: ImportedProjectWorkspace(inspection: finding(), records: r),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Open baseline-copy history'));
      await tester.tap(find.text('Open baseline-copy history'));
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Review isolated proposed copy'));
      await tester.tap(find.text('Review isolated proposed copy'));
      await tester.pumpAndSettle();
      final screen = tester.widget<ImportedCommitEditScreen>(
        find.byType(ImportedCommitEditScreen),
      );
      expect(screen.controller.expectedCopyDigest, isNotNull);
      expect(screen.controller.draft, isNull);
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
    },
  );
  testWidgets(
    'workspace independent proposed-copy history grants no source action',
    (tester) async {
      final r = await fixture.editRecords();
      await tester.pumpWidget(
        MaterialApp(
          home: ImportedProjectWorkspace(inspection: finding(), records: r),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Open proposed-copy history'));
      await tester.tap(find.text('Open proposed-copy history'));
      await tester.pumpAndSettle();
      final screen = tester.widget<ImportedCommitEditScreen>(
        find.byType(ImportedCommitEditScreen),
      );
      expect(screen.controller.historyOnly, true);
      expect(find.byType(TextField), findsNothing);
      expect(screen.controller.canReview, false);
    },
  );
}
