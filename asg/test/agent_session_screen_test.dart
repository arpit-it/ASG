// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/controllers/agent_session_controller.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/views/agent_session_screen.dart';
import 'package:asg/views/project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approved_source_proposer_test.dart' show seed;
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
  TestWidgetsFlutterBinding.ensureInitialized();
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
}
