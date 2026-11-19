// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/controllers/agent_session_controller.dart';
import 'package:asg/controllers/saved_candidate_recovery_controller.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/views/agent_session_screen.dart';
import 'package:asg/views/saved_candidate_recovery_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'candidate_reopen_context_test.dart' show reopenFixture;
import 'candidate_reopen_context_store_test.dart' show startReopen;
import 'planning_conversation_test.dart' show project;
import 'saved_candidate_recovery_controller_test.dart'
    show ReopenInspectionHost;

void main() {
  testWidgets(
    'latest session entry opens production recovery read-only and retains consent at narrow high text',
    (tester) async {
      final f = await reopenFixture();
      final journal = CandidateVerificationStore(f.records, project.id);
      await startReopen(f, journal);
      final hosts = <ReopenInspectionHost>[];
      final sessions = AgentSessionController(
        AgentSessionStore(f.records, project),
        createRecoveryHost: () {
          final h = ReopenInspectionHost();
          hosts.add(h);
          return h;
        },
      );
      sessions.load();
      sessions.open(journal.admittedSession!.sessionId);
      final before = Map.of(f.records.values);
      tester.view.physicalSize = const Size(320, 900);
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
          home: AgentSessionScreen(
            controller: sessions,
            projectName: 'Saved fixture',
          ),
        ),
      );
      final entry = find.byKey(const ValueKey('open-saved-candidate-1'));
      await tester.scrollUntilVisible(
        entry,
        300,
        maxScrolls: 100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(entry);
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(entry).onPressed, isNotNull);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(find.text('Saved candidate recovery'), findsOneWidget);
      expect(find.text('Opened saved run 1'), findsOneWidget);
      expect(hosts.length, 2);
      expect(
        hosts.every(
          (h) => h.verifications == 0 && h.generations == 0 && !h.server,
        ),
        isTrue,
      );
      final verify = find.widgetWithText(
        FilledButton,
        'Verify candidate in sandbox',
      );
      await tester.scrollUntilVisible(
        verify,
        250,
        maxScrolls: 100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(verify);
      await tester.pumpAndSettle();
      expect(tester.widget<FilledButton>(verify).onPressed, isNull);
      expect(f.records.values, before);
      expect(tester.takeException(), isNull);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(f.records.values, before);
      expect(hosts.every((h) => h.disposals == 1), isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'missing context opens no host and retry never backfills or falls back',
    (tester) async {
      final f = await reopenFixture();
      final journal = CandidateVerificationStore(f.records, project.id);
      await startReopen(f, journal);
      f.records.values.remove('studio.candidateReopen.v1.${project.id}.1');
      var hosts = 0;
      final controller = SavedCandidateRecoveryController(
        project: project,
        records: f.records,
        selectedSession: journal.admittedSession!,
        runNumber: 1,
        createHost: () {
          hosts++;
          return ReopenInspectionHost();
        },
      );
      final before = Map.of(f.records.values);
      await tester.pumpWidget(
        MaterialApp(home: SavedCandidateRecoveryScreen(controller: controller)),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('Missing legacy context'), findsOneWidget);
      await tester.tap(find.text('Retry opening saved candidate'));
      await tester.pumpAndSettle();
      expect(hosts, 0);
      expect(f.records.values, before);
      expect(find.text('Verify candidate in sandbox'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
