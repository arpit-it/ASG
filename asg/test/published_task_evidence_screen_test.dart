// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/controllers/agent_session_controller.dart';
import 'package:asg/controllers/published_task_evidence_controller.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/published_task_evidence_store.dart';
import 'package:asg/views/agent_session_screen.dart';
import 'package:asg/views/published_task_evidence_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'planning_conversation_test.dart' show project;
import 'published_task_evidence_store_test.dart' show evidenceFixture;
import 'agent_session_screen_test.dart' show reveal;

void main() {
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
