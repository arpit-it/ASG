// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/controllers/agent_session_controller.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/agent_task_history_store.dart';

import '../tools/fixtures/agent_session_task_history.dart';
import '../tools/fixtures/candidate_reopen.dart' show CandidateReopenFixture;

import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/views/agent_session_screen.dart';
import 'package:asg/views/project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approved_source_proposer_test.dart' show seed;
import 'agent_session_publication_test.dart' show publishedFixture;
import 'agent_session_store_test.dart' show savedRun, selection;
import 'planning_conversation_test.dart' show project;
import 'source_candidate_controller_test.dart' show AtomicRecords;

Future<void> reveal(WidgetTester tester, Finder target, double delta) async {
  await tester.scrollUntilVisible(
    target,
    delta,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.pumpAndSettle();
}

void main() {
  test('labelled decision fixture permits one scoped decision and retains it after supplied evidence changes', () async {
    final f = await CandidateReopenFixture.create(decisionMode: true);
    final parent = AgentSessionController(
      AgentSessionStore(f.uiRecords, TaskHistoryFixture.project),
    )..open('published');
    final number = parent.selected!.dispatches.last.runNumber;
    final c = parent.createPublishedTaskEvidence(number)!..load();
    expect(c.canConsent, isTrue);
    expect(await c.confirm(), isFalse);
    expect(f.decisionRecords.decisionCommits, 0);
    c.setConsent(true);
    expect(await c.confirm(), isTrue);
    final fingerprint = c.decision!.fingerprint;
    expect(f.decisionRecords.decisionCommits, 1);
    expect(f.originalRecordsUnchanged, isTrue);
    expect(f.retainedDecisions, 1);
    c.load();
    expect(c.decision!.fingerprint, fingerprint);
    expect(f.decisionRecords.decisionCommits, 1);
    await f.replaceNamedObservation();
    c.load();
    expect(c.decision!.fingerprint, fingerprint);
    expect(c.evidence!.criteria.first.verdict, contains('not verified'));
    await f.withdrawPublishedSession();
    parent.open('published');
    final withdrawn = parent.createPublishedTaskEvidence(number)!..load();
    expect(withdrawn.decision!.fingerprint, fingerprint);
    expect(withdrawn.canConsent, isFalse);
    expect(f.fixtureMutations, 2);
    expect(f.decisionRecords.unexpectedWrites, 0);
    expect(f.records.writeAttempts, 0);
    expect(f.inspections, 0);
    expect(f.effectAttempts, 0);
    withdrawn.dispose();
    c.dispose();
    parent.dispose();
  });

  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'labelled supplied publication fixture retains read-only projected history',
    () async {
      final f = await CandidateReopenFixture.create();
      final controller = AgentSessionController(
        AgentSessionStore(f.records, TaskHistoryFixture.project),
      );
      controller.open('published');
      expect(controller.selected!.cancellationRequested, isTrue);
      expect(controller.runStatuses.last.publication, isNotNull);
      final review = controller.createPublishedTaskEvidence(
        controller.runStatuses.last.reference.runNumber,
      )!;
      review.load();
      expect(review.error, isNull);
      expect(review.evidence!.criteria, hasLength(4));
      expect(
        review.evidence!.criteria.first.verdict,
        contains('verified against authored named tests'),
      );
      review.dispose();
      expect(f.records.writeAttempts, 0);
      expect(f.unchanged, isTrue);
      expect(f.effectAttempts, 0);
      controller.dispose();
    },
  );

  testWidgets(
    'published task has an explicit read-only acceptance evidence review entry',
    (tester) async {
      final f = await publishedFixture();
      final controller = AgentSessionController(
        AgentSessionStore(f.fixture.records, project),
      )..open(f.session.sessionId);
      final before = Map.of(f.fixture.records.values);
      await tester.pumpWidget(
        MaterialApp(
          home: AgentSessionScreen(
            controller: controller,
            projectName: project.name,
          ),
        ),
      );
      await reveal(
        tester,
        find.textContaining('Published candidate for Tanalyze'),
        250,
      );
      expect(
        find.widgetWithText(OutlinedButton, 'Review published task evidence'),
        findsOneWidget,
      );
      expect(f.fixture.records.values, before);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'published candidate remains a read-only observation at narrow enlarged text after withdrawal',
    (tester) async {
      final f = await publishedFixture();
      final records = f.fixture.records;
      final store = AgentSessionStore(records, project);
      final session = await store.requestCancellation(f.session);
      final controller = AgentSessionController(store)..open(session.sessionId);
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final before = Map.of(records.values);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: AgentSessionScreen(
            controller: controller,
            projectName: project.name,
          ),
        ),
      );
      await reveal(
        tester,
        find.textContaining('Published candidate for Tanalyze'),
        250,
      );
      expect(
        find.textContaining('separately from task completion'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(records.values, before);
      records.values[f.publication.storageKey] = '{invalid-publication';
      final changed = Map.of(records.values);
      controller.open(session.sessionId);
      await tester.pumpAndSettle();
      await reveal(
        tester,
        find.textContaining('Publication evidence is unavailable'),
        250,
      );
      expect(
        find.textContaining('Published candidate for Tanalyze'),
        findsNothing,
      );
      expect(records.values, changed);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'narrow enlarged saved overview distinguishes unresolved and unavailable evidence',
    (tester) async {
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = AtomicRecords();
      await seed(records);
      final store = AgentSessionStore(records, project);
      final initial = await store.create('overview-screen', selection(records));
      final run = await savedRun(records);
      final session = await store.observeRun(initial, 'Tanalyze', run);
      final controller = AgentSessionController(store)..open(session.sessionId);
      final before = Map.of(records.values);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: AgentSessionScreen(
            controller: controller,
            projectName: project.name,
          ),
        ),
      );
      await reveal(
        tester,
        find.textContaining('Unresolved operation: resolve'),
        250,
      );
      expect(find.textContaining('checkpoint: executing'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(records.values, before);
      records.values.remove(
        'studio.agentExecution.v1.candidate-${project.id}-1',
      );
      controller.load();
      await tester.pumpAndSettle();
      await reveal(
        tester,
        find.textContaining('Run evidence is unavailable'),
        250,
      );
      expect(
        find.textContaining('Unresolved operation: resolve'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'explicit use returns selected session without dispatch or storage writes',
    (tester) async {
      final records = AtomicRecords();
      await seed(records);
      final controller = AgentSessionController(
        AgentSessionStore(records, project),
        createSessionId: () => 'selected-route',
      );
      controller.load();
      await controller.create(approved: true);
      final before = Map.of(records.values);
      Object? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async {
                  selected = await Navigator.of(context).push(
                    MaterialPageRoute<Object>(
                      builder: (_) => AgentSessionScreen(
                        controller: controller,
                        projectName: project.name,
                      ),
                    ),
                  );
                },
                child: const Text('Choose session'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Choose session'));
      await tester.pumpAndSettle();
      expect(selected, isNull);
      await reveal(tester, find.text('Use session for source review'), 250);
      await tester.tap(find.text('Use session for source review'));
      await tester.pumpAndSettle();
      expect(selected, isNotNull);
      expect(records.values, before);
      expect(find.text('Choose session'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '320px enlarged consent/create/cancel and reopen remain explicit',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final records = AtomicRecords();
      await seed(records);
      final store = AgentSessionStore(records, project);
      final controller = AgentSessionController(
        store,
        createSessionId: () => 'session-ui',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(320, 600),
              textScaler: TextScaler.linear(2),
            ),
            child: AgentSessionScreen(
              controller: controller,
              projectName: project.name,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(
        tester,
        find.text('Save this selection for the approved Plan'),
        200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save this selection for the approved Plan'));
      await tester.pump();
      await reveal(tester, find.text('Create saved session'), 100);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create saved session'));
      await tester.pumpAndSettle();
      expect(controller.selected!.sessionId, 'session-ui');
      expect(store.sessionIds(), ['session-ui']);
      await reveal(tester, find.text('Request session cancellation'), 250);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Request session cancellation'));
      await tester.pumpAndSettle();
      expect(controller.selected!.cancellationRequested, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(controller.isDisposed, isTrue);
      final before = Map.of(records.values);
      final reopened = AgentSessionController(store);
      await tester.pumpWidget(
        MaterialApp(
          home: AgentSessionScreen(
            controller: reopened,
            projectName: project.name,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await reveal(
        tester,
        find.text('Open session-ui — cancellation requested'),
        200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open session-ui — cancellation requested'));
      await tester.pump();
      expect(reopened.selected!.cancellationRequested, isTrue);
      expect(records.values, before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('revoked approval retains history without auto retry', (
    tester,
  ) async {
    final records = AtomicRecords();
    await seed(records);
    final store = AgentSessionStore(records, project);
    final value = await store.create('older', [
      'Tresolve',
      'Tanalyze',
      'Ttest',
      'Tbuild',
    ]);
    await PlanApprovalStore(records)
        .save(project, ConversationStore(records).load(project.id), false);
    final controller = AgentSessionController(store);
    final before = Map.of(records.values);
    await tester.pumpWidget(
      MaterialApp(
        home: AgentSessionScreen(
          controller: controller,
          projectName: project.name,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Approve the current Plan'), findsOneWidget);
    expect(find.text('Create saved session'), findsNothing);
    await tester.tap(find.text('Open older'));
    await tester.pump();
    expect(controller.selected!.sessionId, value.sessionId);
    expect(records.values, before);
    expect(tester.takeException(), isNull);
  });

  testWidgets('workspace entry opens saved sessions without changing records', (
    tester,
  ) async {
    final records = AtomicRecords();
    await seed(records);
    await tester.pumpWidget(
      MaterialApp(
        home: ProjectWorkspace(project: project, records: records),
      ),
    );
    await tester.pumpAndSettle();
    final before = Map.of(records.values);
    await tester.tap(find.byTooltip('Saved work sessions'));
    await tester.pumpAndSettle();
    expect(find.text('Saved work sessions'), findsOneWidget);
    expect(records.values, before);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'failed save is visible and retains consent without automatic publication',
    (tester) async {
      final records = AtomicRecords();
      await seed(records);
      final store = AgentSessionStore(records, project);
      final controller = AgentSessionController(
        store,
        createSessionId: () => 'failed-ui',
      );
      await tester.pumpWidget(
        MaterialApp(
          home: AgentSessionScreen(
            controller: controller,
            projectName: project.name,
          ),
        ),
      );
      await tester.pumpAndSettle();
      final before = Map.of(records.values);
      records.failCommit = true;
      await reveal(
        tester,
        find.text('Save this selection for the approved Plan'),
        200,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save this selection for the approved Plan'));
      await tester.pump();
      await reveal(tester, find.text('Create saved session'), 100);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create saved session'));
      await tester.pumpAndSettle();
      expect(controller.error, contains('not saved'));
      expect(records.values, before);
      await reveal(
        tester,
        find.textContaining('Session update was not saved'),
        -200,
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Session update was not saved').hitTestable(),
        findsOneWidget,
      );
      records.failCommit = false;
      await tester.pumpAndSettle();
      expect(records.values, before);
      expect(tester.takeException(), isNull);
    },
  );
  for (final id in ['unknown', 'late-result']) {
    testWidgets(
      '320px enlarged task observations are truthful and read-only: $id',
      (tester) async {
        tester.view.physicalSize = const Size(320, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final fixture = await TaskHistoryFixture.create();
        final controller = AgentSessionController(
          AgentSessionStore(fixture.records, TaskHistoryFixture.project),
        )..open(id);
        final count = id == 'unknown' ? 5 : 6;
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: AgentSessionScreen(
              controller: controller,
              projectName: TaskHistoryFixture.project.name,
            ),
          ),
        );
        await reveal(tester, find.text('Task observations ($count)'), 250);
        await tester.tap(find.text('Task observations ($count)'));
        await tester.pumpAndSettle();
        expect(find.text('1. Verification admitted'), findsOneWidget);
        expect(
          find.text('3. Resolve dependencies — recorded exit 0'),
          findsOneWidget,
        );
        expect(find.text('Session withdrawal recorded'), findsOneWidget);
        final finalText = id == 'unknown'
            ? 'Run tests has no saved result. Its outcome is unknown.'
            : '6. Verification attempt finished';
        await reveal(tester, find.text(finalText), 220);
        expect(find.text(finalText).hitTestable(), findsOneWidget);
        expect(
          tester.getTopLeft(find.text('Session withdrawal recorded')).dy,
          lessThan(
            tester
                .getTopLeft(
                  find.text(
                    id == 'unknown'
                        ? '5. Run tests — interrupted; outcome unknown'
                        : '5. Run tests — recorded exit 0',
                  ),
                )
                .dy,
          ),
        );
        expect(find.textContaining('fixture-result-private'), findsNothing);
        expect(find.textContaining('```asg-build'), findsNothing);
        expect(find.textContaining('Build Flutter web — intent'), findsNothing);
        expect(fixture.records.writeAttempts, 0);
        expect(fixture.unchanged, isTrue);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'legacy and corrupt task details do not erase retained run facts',
    (tester) async {
      final fixture = await TaskHistoryFixture.create();
      final store = AgentSessionStore(
        fixture.records,
        TaskHistoryFixture.project,
      );
      final controller = AgentSessionController(store)..open('legacy');
      await tester.pumpWidget(
        MaterialApp(
          home: AgentSessionScreen(
            controller: controller,
            projectName: 'Fixture',
          ),
        ),
      );
      await reveal(
        tester,
        find.text('Task observations are unavailable for this saved run.'),
        250,
      );
      expect(find.textContaining('Unresolved operation: test'), findsOneWidget);
      controller.open('unknown');
      await tester.pumpAndSettle();
      await reveal(tester, find.text('Task observations (5)'), 250);
      fixture.records.values[AgentTaskHistoryStore(
            fixture.records,
            TaskHistoryFixture.project.id,
          ).keyFor(1)] =
          '{private-history-token';
      final before = Map.of(fixture.records.values);
      controller.load();
      await tester.pumpAndSettle();
      await reveal(
        tester,
        find.text('Task observations are unavailable for this saved run.'),
        250,
      );
      expect(find.textContaining('Unresolved operation: test'), findsOneWidget);
      expect(find.textContaining('private-history-token'), findsNothing);
      expect(find.text('Task observations (5)'), findsNothing);
      expect(fixture.records.values, before);
      expect(fixture.records.writeAttempts, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
