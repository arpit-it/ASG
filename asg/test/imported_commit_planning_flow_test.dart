// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/imported_plan_controller.dart';
import 'package:asg/models/imported_commit_context.dart';
import 'package:asg/models/imported_plan.dart';
import 'package:asg/models/project_inspection.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/services/imported_source_proposal_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/views/imported_commit_comparison_screen.dart';
import 'package:asg/views/imported_plan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_commit_comparison_controller_test.dart'
    show CommitHost, baselineRecords, commitController;
import 'imported_commit_comparison_test.dart' show commitObserved;
import 'imported_source_baseline_test.dart' show baselineSaved;
import 'imported_source_proposal_controller_test.dart' show ProposalRecords;
import 'imported_commit_comparison_store_test.dart'
    show actualCommitComparisonFixture;
import 'imported_plan_test.dart' show capturedSourcePlan;

ProjectInspection planningInspection() {
  final m = jsonDecode(baselineSaved().context.recordJson)['metadata'] as Map;
  return ProjectInspection(
    root: m['root'],
    packageName: m['package'],
    dartSdk: m['dartSdk'],
    runners: (m['runners'] as List).cast<String>(),
  );
}

Future<ImportedCommitContext> planningCapture(
  ProposalRecords r, {
  String? commit,
}) async {
  final h = CommitHost(baselineSaved()), c = commitController(r, h);
  if (commit != null) c.setCommit(commit);
  await c.recheck(confirm: (_) async => true);
  final result = await c.preparePlanning(planningInspection());
  c.dispose();
  return result!;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('context preparation is explicit read-only and stable across repeated read events', () async {
    final r = await baselineRecords(baselineSaved()),
        h = CommitHost(baselineSaved()),
        c = commitController(
          await baselineRecords(baselineSaved()),
          CommitHost(baselineSaved()),
        );
    expect(c.canPreparePlanning, false);
    expect(await c.preparePlanning(planningInspection()), isNull);
    c.dispose();
    final owner = commitController(r, h), before = Map.of(r.values);
    await owner.recheck(confirm: (_) async => true);
    final first = await owner.preparePlanning(planningInspection());
    expect(first, isNotNull);
    expect(h.reads, 1);
    expect(r.values, before);
    expect(owner.store.readOwned, false);
    await owner.recheck(confirm: (_) async => true);
    expect(
      (await owner.preparePlanning(planningInspection()))!.digest,
      first!.digest,
    );
    owner.setCommit('d' * 40);
    expect(owner.canPreparePlanning, false);
    expect(await owner.preparePlanning(planningInspection()), isNull);
    owner.dispose();
  });
  test(
    'changed committed bytes can prepare without relabelling working files',
    () async {
      final r = await baselineRecords(baselineSaved()),
          h = CommitHost(baselineSaved());
      h.onRead = (_) async =>
          commitObserved(baselineSaved(), changed: 'test/peer.dart');
      final c = commitController(r, h);
      await c.recheck(confirm: (_) async => true);
      final context = await c.preparePlanning(planningInspection());
      expect(context!.files.last.source.text, 'changed\n');
      expect(context.workingTree, 'unknown');
      expect(context.sourceVerified, false);
      c.dispose();
    },
  );
  for (final stop in ['Stop', 'dispose', 'commit', 'requirements']) {
    test(
      'pending context preparation retains lease and rejects $stop',
      () async {
        final r = await baselineRecords(baselineSaved()),
            h = CommitHost(baselineSaved()),
            c = commitController(r, CommitHost(baselineSaved()));
        await c.recheck(confirm: (_) async => true);
        r.gate = Completer<void>();
        final pending = c.preparePlanning(planningInspection());
        await Future<void>.delayed(Duration.zero);
        expect(c.busy, true);
        expect(c.store.readOwned, true);
        final other = commitController(r, h);
        await other.recheck(confirm: (_) async => true);
        expect(h.reads, 0);
        if (stop == 'Stop') await c.cancel();
        if (stop == 'dispose') c.dispose();
        if (stop == 'commit') c.setCommit('d' * 40);
        if (stop == 'requirements') {
          r.values[RequirementsStore.key(
            InspectedFolderStore.workspaceId(baselineSaved().root),
          )] = jsonEncode(
            RequirementsBoard(revision: 1).toJson(),
          );
        }
        r.gate!.complete();
        expect(await pending, isNull);
        expect(c.store.readOwned, false);
        c.dispose();
        other.dispose();
      },
    );
  }
  test('manual immutable plan needs its own draft and preserves historical comparison', () async {
    final r = await baselineRecords(baselineSaved()), saved = baselineSaved();
    r.values[ImportedPlanStore.key(saved.root)] = jsonEncode(
      saved.plan.toJson(),
    );
    final context = await planningCapture(r),
        p = ImportedPlanController(
          saved.root,
          ImportedPlanStore(r, capturedCommit: context),
          inspection: planningInspection(),
        );
    await p.load();
    expect(p.approved, false);
    final before = r.values[ImportedPlanStore.key(saved.root)];
    await p.decide(true);
    expect(p.error, isNotNull);
    expect(r.values[ImportedPlanStore.key(saved.root)], before);
    await p.saveDraft('Review committed bytes');
    expect(p.error, isNull);
    expect(p.approved, false);
    await p.decide(true);
    expect(p.approved, true);
    expect(
      ImportedSourceProposalStore(r).history(saved.root).record!.encode(),
      saved.encode(),
    );
    final reopened = ImportedPlanController(
      saved.root,
      ImportedPlanStore(
        r,
        capturedCommit: ImportedCommitContext.restore(p.plan!.context),
      ),
      inspection: planningInspection(),
    );
    await reopened.load();
    expect(reopened.approved, true);
    final other = await planningCapture(r, commit: 'd' * 40);
    final moved = ImportedPlanController(
      saved.root,
      ImportedPlanStore(r, capturedCommit: other),
      inspection: planningInspection(),
    );
    await moved.load();
    expect(moved.approved, false);
    p.dispose();
    reopened.dispose();
    moved.dispose();
  });
  for (final mode in ['failure', 'dispose', 'requirements', 'concurrent']) {
    test(
      'committed plan pending save preserves prior record on $mode',
      () async {
        final r = await baselineRecords(baselineSaved()),
            context = await planningCapture(
              await baselineRecords(baselineSaved()),
            );
        final root = baselineSaved().root,
            p = ImportedPlanController(
              baselineSaved().root,
              ImportedPlanStore(r, capturedCommit: context),
              inspection: planningInspection(),
            );
        await p.load();
        await p.saveDraft('Last working');
        final before = r.values[ImportedPlanStore.key(root)];
        r.writeGate = Completer<void>();
        final pending = p.decide(true);
        await Future<void>.delayed(Duration.zero);
        if (mode == 'failure') r.failWrites = true;
        if (mode == 'dispose') p.dispose();
        if (mode == 'requirements') {
          r.values[RequirementsStore.key(
            InspectedFolderStore.workspaceId(root),
          )] = jsonEncode(
            RequirementsBoard(revision: 1).toJson(),
          );
        }
        if (mode == 'concurrent') {
          r.values[ImportedPlanStore.key(root)] = jsonEncode(
            ImportedPlan(
              text: 'Other winning draft',
              context: context.recordJson,
              approved: false,
              recordedAt: DateTime.utc(2026),
            ).toJson(),
          );
        }
        final expected = r.values[ImportedPlanStore.key(root)];
        r.writeGate!.complete();
        await pending;
        expect(
          r.values[ImportedPlanStore.key(root)],
          mode == 'concurrent' ? expected : before,
        );
        expect(p.approved, false);
        if (!p.isDisposed) p.dispose();
      },
    );
  }
  test('typed contexts are mutually exclusive in plan storage', () async {
    final r = await baselineRecords(baselineSaved()),
        context = await planningCapture(await baselineRecords(baselineSaved()));
    expect(
      () => ImportedPlanStore(
        r,
        capturedCommit: context,
        capturedSource: capturedSourcePlan(),
      ),
      throwsArgumentError,
    );
  });
  test(
    'actual Mac committed planning closes and reopens native DB preserving source and history',
    () async {
      final e = await actualCommitComparisonFixture(exercisePlanning: true);
      expect(e['manualDraftAndApprovalReopened'], true);
      expect(e['ordinaryApprovalInactive'], true);
      expect(e['savedComparisonPreserved'], true);
      expect(e['onlyPlanRecordChanged'], true);
      expect(e['temporaryRootRemoved'], true);
    },
    skip: !Platform.isMacOS
        ? 'Actual installed Mac Python/Git; no other-platform claim.'
        : false,
  );
  testWidgets(
    'explicit review entry opens immutable plan with no implicit save or additional read',
    (tester) async {
      final r = await baselineRecords(baselineSaved()),
          h = CommitHost(baselineSaved()),
          c = commitController(r, h);
      await c.recheck(confirm: (_) async => true);
      final before = Map.of(r.values);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => ImportedCommitComparisonScreen(
              controller: c,
              inspection: planningInspection(),
              onPlan: (captured) {
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ImportedPlanScreen(
                      controller: ImportedPlanController(
                        baselineSaved().root,
                        ImportedPlanStore(r, capturedCommit: captured),
                        inspection: planningInspection(),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review committed source and plan'));
      await tester.tap(find.text('Review committed source and plan'));
      await tester.pumpAndSettle();
      expect(find.text('Imported project plan'), findsOneWidget);
      expect(find.text('Commit: ${'a' * 40}'), findsOneWidget);
      expect(r.values, before);
      expect(h.reads, 1);
      await tester.scrollUntilVisible(
        find.byType(TextField),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byType(TextField),
        'User-authored committed plan',
      );
      await tester.scrollUntilVisible(
        find.text('Save draft'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save draft'));
      await tester.pumpAndSettle();
      expect(
        ImportedPlanStore(r).load(baselineSaved().root)!.context,
        contains('captured-imported-commit-context'),
      );
      expect(ImportedPlanStore(r).load(baselineSaved().root)!.approved, false);
    },
  );
  testWidgets(
    'replaced comparison controller cannot deliver pending planning context',
    (tester) async {
      final r = await baselineRecords(baselineSaved()),
          h = CommitHost(baselineSaved());
      final c = commitController(r, h);
      await c.recheck(confirm: (_) async => true);
      var navigations = 0;
      final inspection = planningInspection();
      await tester.pumpWidget(
        MaterialApp(
          home: ImportedCommitComparisonScreen(
            controller: c,
            inspection: inspection,
            onPlan: (_) => navigations++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      r.gate = Completer<void>();
      await tester.ensureVisible(find.text('Review committed source and plan'));
      await tester.tap(find.text('Review committed source and plan'));
      await tester.pump();
      final replacement = commitController(r, CommitHost(baselineSaved()));
      await tester.pumpWidget(
        MaterialApp(
          home: ImportedCommitComparisonScreen(
            controller: replacement,
            inspection: inspection,
            onPlan: (_) => navigations++,
          ),
        ),
      );
      r.gate!.complete();
      await tester.pumpAndSettle();
      expect(c.isDisposed, true);
      expect(navigations, 0);
      expect(c.store.readOwned, false);
      expect(h.reads, 1);
    },
  );
  testWidgets(
    'narrow large-text committed plan preserves review and save controls',
    (tester) async {
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final r = await baselineRecords(baselineSaved());
      final captured = await planningCapture(r);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ImportedPlanScreen(
            controller: ImportedPlanController(
              baselineSaved().root,
              ImportedPlanStore(r, capturedCommit: captured),
              inspection: planningInspection(),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Review captured source text'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review captured source text'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review captured source text'));
      await tester.pumpAndSettle();
      expect(find.text(baselineSaved().context.files.first.text), findsWidgets);
      await tester.scrollUntilVisible(
        find.byType(TextField),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), 'Narrow committed plan');
      await tester.scrollUntilVisible(
        find.text('Save draft'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Save draft'));
      await tester.pumpAndSettle();
      expect(ImportedPlanStore(r).load(baselineSaved().root)!.approved, false);
      expect(tester.takeException(), isNull);
    },
  );
  test(
    'final idle notification disposal cannot deliver a prepared context',
    () async {
      final r = await baselineRecords(baselineSaved()),
          h = CommitHost(baselineSaved());
      final c = commitController(r, h);
      await c.recheck(confirm: (_) async => true);
      c.addListener(() {
        if (!c.busy && !c.isDisposed) c.dispose();
      });
      final prepared = await c.preparePlanning(planningInspection());
      expect(c.isDisposed, true);
      expect(prepared, isNull);
      expect(c.store.readOwned, false);
    },
  );
}
