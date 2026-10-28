// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/controllers/requirement_check_report_controller.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/views/requirement_check_report_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'named_check_observation_test.dart' as named;
import 'manual_check_observation_test.dart' show Transactions;
import 'requirement_check_report_test.dart' show project;

Map<String, dynamic> acceptance(RequirementCheckReportStore store) =>
    (jsonDecode(store.load(project).evidenceJson)['requirements'] as List)
            .first['acceptanceEvidence']
        as Map<String, dynamic>;

void main() {
  for (final passed in [true, false]) {
    test(
      'copied declarations resolve exact named outcome $passed and reopen',
      () async {
        final records = await named.fixture();
        final store = RequirementCheckReportStore(records);
        expect(acceptance(store)['directChecks'], isEmpty);
        await named.record(store, passed);
        final before = Map.of(records.data);
        final evidence = acceptance(store);
        final check = (evidence['declaredChecks'] as List).first;
        expect(
          check['status'],
          passed ? 'savedTargetPassed' : 'savedTargetNotPassed',
        );
        expect(
          check['result']['result']['targetedTest']['status'],
          passed ? 'passed' : 'notPassed',
        );
        expect(
          check['result']['requirementSha256'],
          evidence['requirementSha256'],
        );
        expect(
          check['result']['runSha256'],
          store.load(project).revisionIdentity!.savedRunSha256,
        );
        expect(evidence['status'], 'unverified');
        expect((evidence['declaredChecks'] as List).last['status'], 'missing');
        expect((evidence['directChecks'] as List).single, check);
        final reopened = Transactions()..data.addAll(before);
        expect(acceptance(RequirementCheckReportStore(reopened)), evidence);
        expect(records.data, before);
        expect(jsonEncode(evidence), isNot(contains('PRIVATE_')));
      },
    );
  }

  for (final change in ['requirement', 'target', 'source', 'failedRun']) {
    test('copied direct outcome is stale after $change', () async {
      final records = await named.fixture();
      final store = RequirementCheckReportStore(records);
      await named.record(store, true);
      if (change == 'requirement' || change == 'target') {
        final boardStore = RequirementsStore(records);
        final board = boardStore.load('p');
        final first = board.requirements.first;
        await records.setString(
          RequirementsStore.key('p'),
          jsonEncode(
            RequirementsBoard(
              revision: board.revision,
              requirements: [
                ProjectRequirement(
                  id: first.id,
                  title: first.title,
                  acceptance: change == 'requirement'
                      ? 'Edited acceptance'
                      : first.acceptance,
                  checks: [
                    for (final c in first.checks)
                      AcceptanceCheckDefinition(
                        id: c.id,
                        type: c.type,
                        expectation: c.expectation,
                        target: change == 'target' && c.target != null
                            ? const FlutterTestTarget(
                                file: 'test/other_test.dart',
                                name: 'other',
                              )
                            : c.target,
                      ),
                  ],
                ),
              ],
              tasks: board.tasks,
            ).toJson(),
          ),
        );
      } else {
        final generation = SourceGenerationStore(records);
        final saved = generation.load('p')!;
        await generation.save(
          'p',
          GeneratedProject.fromJson({
            ...saved.toJson(),
            if (change == 'source')
              'sources': {...saved.sources, 'lib/main.dart': 'f' * 64},
            if (change == 'failedRun') 'phase': 'failed',
          }),
        );
      }
      final evidence = acceptance(store);
      expect((evidence['declaredChecks'] as List).first['status'], 'stale');
      expect((evidence['directChecks'] as List).single['result'], isNotNull);
      expect(evidence['status'], 'unverified');
    });
  }

  test('manual outcomes stay self-reported and unrelated automated checks stay missing', () async {
    final records = await named.fixture();
    final store = RequirementCheckReportStore(records);
    for (final passed in [true, false]) {
      await store.recordManualObservation(
        project,
        store.load(project),
        'R1',
        'Manual',
        passed,
        DateTime.utc(2026, 10, 28),
        authorized: () => true,
      );
      final evidence = acceptance(store);
      expect((evidence['declaredChecks'] as List).first['status'], 'missing');
      expect(
        (evidence['declaredChecks'] as List).last['status'],
        passed ? 'manuallyReportedPassed' : 'manuallyReportedFailed',
      );
      expect(evidence['status'], 'unverified');
    }
  });

  test(
    'advisory declarations never consume a previous automated outcome',
    () async {
      final records = await named.fixture();
      final store = RequirementCheckReportStore(records);
      await named.record(store, true);
      final board = RequirementsStore(records).load('p');
      final first = board.requirements.first;
      await records.setString(
        RequirementsStore.key('p'),
        jsonEncode(
          RequirementsBoard(
            revision: board.revision,
            requirements: [
              ProjectRequirement(
                id: first.id,
                title: first.title,
                acceptance: first.acceptance,
                checks: const [
                  AcceptanceCheckDefinition(
                    id: 'Auto',
                    type: AcceptanceCheckType.advisory,
                    expectation: 'Model opinion',
                  ),
                ],
              ),
            ],
            tasks: board.tasks,
          ).toJson(),
        ),
      );
      final evidence = acceptance(store);
      expect(
        (evidence['declaredChecks'] as List).single['status'],
        'advisoryOnly',
      );
      expect((evidence['declaredChecks'] as List).single['result'], isNull);
      expect(evidence['directChecks'], isEmpty);
      expect(evidence['status'], 'unverified');
    },
  );

  testWidgets('narrow enlarged report displays the exported check status', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = await named.fixture();
    final store = RequirementCheckReportStore(records);
    await named.record(store, false);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: RequirementCheckReportScreen(
          controller: RequirementCheckReportController(project, store),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Automated check: saved target did not pass'),
      200,
    );
    expect(find.text('Acceptance criteria: not verified'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
