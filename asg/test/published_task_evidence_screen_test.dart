// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/controllers/agent_session_controller.dart';
import 'package:asg/controllers/published_task_evidence_controller.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/agent_task_decision_store.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/published_task_evidence_store.dart';
import 'package:asg/views/agent_session_screen.dart';
import 'package:asg/views/published_task_evidence_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'planning_conversation_test.dart' show project;
import 'agent_task_decision_store_test.dart' show dependentPublication;
import 'published_task_evidence_store_test.dart' show evidenceFixture;
import 'agent_session_screen_test.dart' show reveal;
import '../tools/fixtures/candidate_reopen.dart' show CandidateReopenFixture;
import '../tools/fixtures/agent_session_task_history.dart'
    show TaskHistoryFixture;

import 'package:asg/models/prerequisite_preparation_evidence.dart';

void main() {
  testWidgets(
    'labelled dependent preparation fixture renders direct, different and missing proof at narrow double text without writes',
    (tester) async {
      final f = await CandidateReopenFixture.create(preparationMode: true);
      final session = AgentSessionStore(
        f.uiRecords,
        TaskHistoryFixture.project,
      ).load('published')!;
      final c = PublishedTaskEvidenceController(
        PublishedTaskEvidenceStore(f.uiRecords, TaskHistoryFixture.project),
        session,
        session.dispatches.last.runNumber,
      );
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: PublishedTaskEvidenceScreen(controller: c),
        ),
      );
      expect(
        c.preparationReview!.prerequisites.single.state,
        PrerequisitePreparationState.directRecordedLink,
      );
      await reveal(
        tester,
        find.textContaining(
          'Recorded working base and reviewed source map match',
        ),
        200,
      );
      expect(f.originalRecordsUnchanged, isTrue);
      expect(f.unchanged, isTrue);
      f.mutatePreparation(remove: false);
      c.load();
      await tester.pumpAndSettle();
      expect(
        c.preparationReview!.prerequisites.single.state,
        PrerequisitePreparationState.noDirectMatch,
      );
      await reveal(
        tester,
        find.textContaining('No direct recorded preparation match.'),
        200,
      );
      f.mutatePreparation(remove: true);
      c.load();
      await tester.pumpAndSettle();
      expect(
        c.preparationReview!.prerequisites.single.state,
        PrerequisitePreparationState.unavailable,
      );
      await reveal(
        tester,
        find.textContaining('Preparation proof is unavailable.'),
        200,
      );
      expect(c.decision, isNotNull);
      expect(f.retainedDecisions, 2);
      expect(f.decisionRecords.decisionCommits, 0);
      expect(f.decisionRecords.unexpectedWrites, 0);
      expect(f.records.writeAttempts, 0);
      expect(f.inspections, 0);
      expect(f.effectAttempts, 0);
      expect(f.fixtureMutations, 2);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'retained dependent review shows recorded preparation provenance separately from authored-check completion',
    (tester) async {
      final first = await evidenceFixture(
        allAuthoredRules: true,
        taskId: 'Tresolve',
      );
      final decisions = AgentTaskDecisionStore(first.records, project);
      final prior = await decisions.confirm(
        decisions.select(first.session, first.run.number),
        consent: true,
        authorized: () => true,
      );
      final next = await dependentPublication(first);
      final retained = await decisions.confirm(
        decisions.select(
          next.session,
          next.run.number,
          prerequisites: {'Tresolve': first.run.number},
        ),
        consent: true,
        authorized: () => true,
      );
      expect(retained.evidence.prerequisites.single.sha256, prior.fingerprint);
      final before = Map.of(first.records.values);
      final c = PublishedTaskEvidenceController(
        PublishedTaskEvidenceStore(first.records, project),
        next.session,
        next.run.number,
      );
      await tester.pumpWidget(
        MaterialApp(home: PublishedTaskEvidenceScreen(controller: c)),
      );
      expect(c.decision?.fingerprint, retained.fingerprint);
      await reveal(
        tester,
        find.text(
          'Selected historical prerequisite Tresolve: run ${first.run.number}',
        ),
        200,
      );
      expect(first.records.values, before);
      expect(find.text('Recorded preparation provenance'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'narrow double-text consent saves a retained decision independently of later current evidence',
    (tester) async {
      final f = await evidenceFixture(
        allAuthoredRules: true,
        taskId: 'Tresolve',
      );
      final c = PublishedTaskEvidenceController(
        PublishedTaskEvidenceStore(f.records, project),
        f.session,
        f.run.number,
      );
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final before = Map.of(f.records.values);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: PublishedTaskEvidenceScreen(controller: c),
        ),
      );
      expect(f.records.values, before);
      final button = find.widgetWithText(
        OutlinedButton,
        'Record authored-check completion decision',
      );
      expect(c.canConfirm, isFalse);
      await reveal(tester, find.byType(CheckboxListTile), 200);
      await tester.tap(find.byType(Checkbox));
      await tester.pumpAndSettle();
      await reveal(tester, button, 200);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(c.decision, isNotNull);
      expect(f.records.values.length, before.length + 1);
      for (final e in before.entries) {
        expect(f.records.values[e.key], e.value);
      }
      f.records.values['studio.generation.v1.${project.id}'] =
          '{changed working';
      c.load();
      await tester.pumpAndSettle();
      expect(c.decision, isNotNull);
      expect(c.error, contains('unavailable'));
      tester
          .state<ScrollableState>(find.byType(Scrollable).first)
          .position
          .jumpTo(0);
      await tester.pumpAndSettle();
      await reveal(
        tester,
        find.text('Retained authored-check completion decision'),
        200,
      );
      expect(
        find.text('Retained authored-check completion decision'),
        findsOneWidget,
      );
      expect(find.byType(CheckboxListTile), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'passing authored contracts offer an explicit completion decision',
    (tester) async {
      final f = await evidenceFixture(allAuthoredRules: true);
      final report = RequirementCheckReportStore(f.records).load(project);
      final requirement = report.results
          .firstWhere((r) => r.requirement.id == 'R1')
          .requirement;
      expect(report.requirementVerifiedAgainstChecks(requirement), isTrue);
      final before = Map.of(f.records.values);
      final c = PublishedTaskEvidenceController(
        PublishedTaskEvidenceStore(f.records, project),
        f.session,
        f.run.number,
      );
      await tester.pumpWidget(
        MaterialApp(home: PublishedTaskEvidenceScreen(controller: c)),
      );
      expect(c.evidence, isNotNull);
      expect(
        find.text('Record authored-check completion decision'),
        findsOneWidget,
      );
      expect(f.records.values, before);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'production session route scopes criterion facts read-only at narrow double text',
    (tester) async {
      final f = await evidenceFixture();
      final session = await AgentSessionStore(
        f.records,
        project,
      ).requestCancellation(f.session);
      final parent = AgentSessionController(
        AgentSessionStore(f.records, project),
      )..open(session.sessionId);
      tester.view.physicalSize = const Size(320, 740);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final before = Map.of(f.records.values);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: AgentSessionScreen(
            controller: parent,
            projectName: project.name,
          ),
        ),
      );
      await reveal(tester, find.text('Review published task evidence'), 250);
      await tester.tap(find.text('Review published task evidence'));
      await tester.pumpAndSettle();
      expect(find.byType(PublishedTaskEvidenceScreen), findsOneWidget);
      await reveal(
        tester,
        find.textContaining('verified against authored named tests'),
        250,
      );
      expect(
        find.textContaining('verified against authored named tests'),
        findsOneWidget,
      );
      expect(find.text('Unrelated requirement'), findsNothing);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.byType(FilledButton), findsNothing);
      expect(tester.takeException(), isNull);
      expect(f.records.values, before);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets(
    'later working output makes reload unavailable without retargeting; restoration can retry',
    (tester) async {
      final f = await evidenceFixture(withRules: false);
      final c = PublishedTaskEvidenceController(
        PublishedTaskEvidenceStore(f.records, project),
        f.session,
        f.run.number,
      );
      await tester.pumpWidget(
        MaterialApp(home: PublishedTaskEvidenceScreen(controller: c)),
      );
      expect(
        find.text('No authored criteria. Acceptance remains unverified.'),
        findsOneWidget,
      );
      final key = 'studio.generation.v1.${project.id}',
          original = f.records.getString('studio.generation.v1.${project.id}')!;
      final changed = jsonDecode(original) as Map<String, dynamic>;
      changed['directory'] = '/private-other-working';
      f.records.values[key] = jsonEncode(changed);
      final before = Map.of(f.records.values);
      await tester.tap(find.byTooltip('Reload saved evidence'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('unavailable for this saved selection'),
        findsOneWidget,
      );
      expect(
        find.text('No authored criteria. Acceptance remains unverified.'),
        findsNothing,
      );
      expect(find.textContaining('/private-other-working'), findsNothing);
      expect(f.records.values, before);
      f.records.values[key] = original;
      await tester.tap(find.text('Retry saved evidence review'));
      await tester.pumpAndSettle();
      expect(
        find.text('No authored criteria. Acceptance remains unverified.'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(c.isDisposed, isTrue);
    },
  );
}
