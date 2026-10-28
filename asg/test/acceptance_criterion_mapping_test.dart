// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/controllers/requirements_controller.dart';
import 'package:asg/controllers/requirement_check_report_controller.dart';
import 'package:asg/models/portable_export_redaction.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/portable_requirements_store.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/views/requirements_screen.dart';
import 'package:asg/views/requirement_check_report_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'named_check_observation_test.dart' as named;
import 'manual_check_observation_test.dart' show Transactions;
import 'requirement_check_report_test.dart' show prepare, project;
import 'board_mapped_build_plan_test.dart' show sharedBoard;

AcceptanceCriterionDefinition criterion({
  String id = 'AC1',
  String text = 'Saved 中文 item appears',
  List<String> checkIds = const ['Auto'],
}) => AcceptanceCriterionDefinition(id: id, text: text, checkIds: checkIds);

RequirementsBoard mappedBoard({List<AcceptanceCriterionDefinition>? criteria}) {
  final board = sharedBoard(done: true);
  final first = board.requirements.first;
  return RequirementsBoard(
    requirements: [
      ProjectRequirement(
        id: first.id,
        title: first.title,
        acceptance: first.acceptance,
        criteria: criteria ?? [criterion(), criterion(id: 'AC2', checkIds: [])],
        checks: const [
          AcceptanceCheckDefinition(
            id: 'Auto',
            type: AcceptanceCheckType.automated,
            expectation: 'Opens app',
            target: named.target,
          ),
          AcceptanceCheckDefinition(
            id: 'Manual',
            type: AcceptanceCheckType.manual,
            expectation: 'Observe keyboard',
          ),
          AcceptanceCheckDefinition(
            id: 'Advice',
            type: AcceptanceCheckType.advisory,
            expectation: 'Model opinion',
          ),
        ],
      ),
      ...board.requirements.skip(1),
    ],
    tasks: board.tasks,
  );
}

Future<Transactions> fixture() async {
  final records = Transactions();
  final saved = await prepare(records, board: mappedBoard());
  await SourceGenerationStore(records).save('p', saved);
  return records;
}

List<dynamic> copiedCriteria(RequirementCheckReportStore store) =>
    jsonDecode(
          store.load(project).evidenceJson,
        )['requirements'][0]['acceptanceEvidence']['criteria']
        as List;

void main() {
  test(
    'direct evidence rejects detached declarations and requirements',
    () async {
      final records = await fixture();
      final store = RequirementCheckReportStore(records);
      await named.record(store, true);
      final report = store.load(project);
      final requirement = report.results.first.requirement;
      final check = requirement.checks.first;
      expect(
        report.directCheck(requirement, check).status,
        'savedTargetPassed',
      );
      for (final detached in [
        AcceptanceCheckDefinition(
          id: check.id,
          type: check.type,
          expectation: 'A different claim',
          target: check.target,
        ),
        AcceptanceCheckDefinition(
          id: check.id,
          type: AcceptanceCheckType.manual,
          expectation: check.expectation,
        ),
        AcceptanceCheckDefinition(
          id: 'Unknown',
          type: check.type,
          expectation: check.expectation,
          target: check.target,
        ),
        AcceptanceCheckDefinition(
          id: check.id,
          type: check.type,
          expectation: check.expectation,
          target: const FlutterTestTarget(
            file: 'test/other_test.dart',
            name: 'other',
          ),
        ),
      ]) {
        final evidence = report.directCheck(requirement, detached);
        expect(evidence.status, 'stale');
        expect(evidence.result, isNull);
      }
      final changed = ProjectRequirement(
        id: requirement.id,
        title: requirement.title,
        acceptance: 'Changed requirement',
        checks: requirement.checks,
        criteria: requirement.criteria,
      );
      expect(report.directCheck(changed, check).status, 'stale');
      expect(report.directCheck(changed, check).result, isNull);
      final reopened = Transactions()..data.addAll(records.data);
      final reopenedReport = RequirementCheckReportStore(reopened)
          .load(project);
      expect(
        reopenedReport.directCheck(requirement, check).status,
        'savedTargetPassed',
      );
      expect(reopenedReport.directCheck(changed, check).status, 'stale');
    },
  );

  test('legacy serialization unchanged; criteria and mappings immutable', () {
    final legacy = ProjectRequirement(
      id: 'R1',
      title: 'Save',
      acceptance: 'Save.',
    );
    expect(legacy.toJson().keys, ['id', 'title', 'acceptance']);
    expect(ProjectRequirement.fromJson(legacy.toJson()).criteria, isEmpty);
    final refs = ['Auto'];
    final criteria = [criterion(checkIds: refs)];
    final first = mappedBoard(criteria: criteria).requirements.first;
    refs.clear();
    criteria.clear();
    expect(first.criteria.single.checkIds, ['Auto']);
    expect(() => first.criteria.clear(), throwsUnsupportedError);
    expect(
      () => first.criteria.single.checkIds.clear(),
      throwsUnsupportedError,
    );
  });

  test(
    'criteria round-trip through saved store and redacted portable archive',
    () async {
      final records = Transactions();
      final store = RequirementsStore(records);
      final saved = await store.save('p', RequirementsBoard(), mappedBoard());
      expect(store.load('p').toJson(), saved.toJson());
      final portable = PortableRequirementsStore(records).load('p');
      final archive = PortableProjectArchive(
        requirements: portable,
        messages: [],
      );
      expect(
        PortableProjectArchive.decode(archive.encode()).requirements.toJson(),
        saved.toJson(),
      );
      final redacted = PortableExportRedaction.apply(archive, '中文').archive;
      final selected = redacted.requirements.requirements.first.criteria.first;
      expect(selected.text, contains('[redacted]'));
      expect(selected.id, 'AC1');
      expect(selected.checkIds, ['Auto']);
      expect(
        saved.document('Project'),
        contains('Criterion AC1: Saved 中文 item appears'),
      );
      expect(
        saved.document('Project'),
        contains('Mapped checks: Auto; acceptance not verified.'),
      );
    },
  );

  test(
    'invalid criterion identities and references retain saved revision',
    () async {
      final records = Transactions();
      final store = RequirementsStore(records);
      await store.save('p', RequirementsBoard(), mappedBoard());
      final before = Map.of(records.data);
      final controller = RequirementsController('p', store)..load();
      for (final values in [
        [criterion(), criterion()],
        [criterion(id: '../bad')],
        [criterion(text: ' ')],
        [criterion(text: 'x' * 501)],
        [
          criterion(checkIds: ['Auto', 'Auto']),
        ],
        [
          criterion(checkIds: ['Unknown']),
        ],
        List.generate(11, (i) => criterion(id: 'AC$i')),
      ]) {
        expect(
          await controller.saveRequirement(
            mappedBoard(criteria: values).requirements.first,
            editing: true,
          ),
          isFalse,
        );
        expect(records.data, before);
      }
      final original = mappedBoard().requirements.first;
      expect(
        await controller.saveRequirement(
          ProjectRequirement(
            id: original.id,
            title: original.title,
            acceptance: original.acceptance,
            criteria: original.criteria,
            checks: original.checks.skip(1).toList(),
          ),
          editing: true,
        ),
        isFalse,
      );
      expect(records.data, before);
      controller.dispose();
    },
  );

  test(
    'malformed optional criteria fail instead of silently dropping data',
    () {
      final legacy = ProjectRequirement(
        id: 'R1',
        title: 'Save',
        acceptance: 'Save.',
      ).toJson();
      for (final value in [
        null,
        {},
        'bad',
        [
          {
            'id': 'AC',
            'text': 'text',
            'checkIds': [1],
          },
        ],
        [
          {'id': 'AC', 'text': 'text', 'checkIds': [], 'extra': true},
        ],
      ]) {
        expect(
          () => ProjectRequirement.fromJson({...legacy, 'criteria': value}),
          throwsA(anything),
        );
      }
    },
  );

  for (final passed in [true, false]) {
    test(
      'criterion projection resolves only authored checks; outcome $passed is not acceptance',
      () async {
        final records = await fixture();
        final store = RequirementCheckReportStore(records);
        expect(copiedCriteria(store)[0]['checks'][0]['status'], 'missing');
        expect(copiedCriteria(store)[0]['checkSummary'], 'missing');
        await named.record(store, passed);
        final rows = copiedCriteria(store);
        expect(
          rows[0]['checks'][0]['status'],
          passed ? 'savedTargetPassed' : 'savedTargetNotPassed',
        );
        expect(
          rows[0]['checks'][0]['result']['runSha256'],
          store.load(project).revisionIdentity!.savedRunSha256,
        );
        expect(rows[0]['status'], 'unverified');
        expect(
          rows[0]['checkSummary'],
          passed ? 'automatedChecksPassed' : 'failed',
        );
        expect(rows[0]['checks'], hasLength(1));
        expect(rows[1]['mappingStatus'], 'unmapped');
        expect(rows[1]['checkSummary'], 'unmapped');
        expect(rows[1]['checks'], isEmpty);
        final reopened = Transactions()..data.addAll(records.data);
        expect(copiedCriteria(RequirementCheckReportStore(reopened)), rows);
        expect(jsonEncode(rows), isNot(contains('PRIVATE_OUTPUT')));
      },
    );
  }

  test(
    'criterion edits invalidate approval, task progress and named observations',
    () async {
      final records = await fixture();
      final reports = RequirementCheckReportStore(records);
      await named.record(reports, true);
      final before = reports.load(project);
      final controller = RequirementsController('p', RequirementsStore(records))
        ..load();
      expect(
        await controller.saveRequirement(
          mappedBoard(criteria: [criterion(text: 'Changed exact criterion')])
              .requirements
              .first,
          editing: true,
        ),
        isTrue,
      );
      final after = reports.load(project);
      expect(after.savedInputsCurrent, isFalse);
      expect(
        after.results.first.acceptance.requirementSha256,
        isNot(before.results.first.acceptance.requirementSha256),
      );
      expect(copiedCriteria(reports)[0]['checks'][0]['status'], 'stale');
      expect(copiedCriteria(reports)[0]['checkSummary'], 'stale');
      expect(
        controller.board!.tasks
            .where((t) => t.requirementId == 'R1')
            .every((t) => t.status == TaskStatus.queued),
        isTrue,
      );
      controller.dispose();
    },
  );

  test('manual and advisory mappings stay unverified with a successful generic run', () async {
    final records = Transactions();
    final saved = await prepare(
      records,
      board: mappedBoard(
        criteria: [
          criterion(checkIds: ['Manual', 'Advice']),
        ],
      ),
    );
    await SourceGenerationStore(records).save('p', saved);
    final store = RequirementCheckReportStore(records);
    await store.recordManualObservation(
      project,
      store.load(project),
      'R1',
      'Manual',
      true,
      DateTime.utc(2026, 10, 28),
      authorized: () => true,
    );
    final row = copiedCriteria(store).single;
    expect(row['status'], 'unverified');
    expect(row['checkSummary'], 'notAutomated');
    expect(row['checks'][0]['status'], 'manuallyReportedPassed');
    expect(row['checks'][1]['status'], 'advisoryOnly');
  });

  for (final manualPassed in [true, false]) {
    test(
      'mixed mapped evidence cannot pass; manual outcome $manualPassed',
      () async {
        final records = Transactions();
        final saved = await prepare(
          records,
          board: mappedBoard(
            criteria: [
              criterion(checkIds: ['Auto', 'Manual']),
            ],
          ),
        );
        await SourceGenerationStore(records).save('p', saved);
        final store = RequirementCheckReportStore(records);
        await named.record(store, true);
        expect(copiedCriteria(store).single['checkSummary'], 'missing');
        await store.recordManualObservation(
          project,
          store.load(project),
          'R1',
          'Manual',
          manualPassed,
          DateTime.utc(2026, 10, 28),
          authorized: () => true,
        );
        final row = copiedCriteria(store).single;
        expect(row['checkSummary'], manualPassed ? 'notAutomated' : 'failed');
        expect(row['status'], 'unverified');
        // Failure dominates missing/advisory evidence, but never a stale run.
        await named.record(store, false);
        expect(copiedCriteria(store).single['checkSummary'], 'failed');
        final controller = RequirementsController(
          'p',
          RequirementsStore(records),
        )..load();
        await controller.saveRequirement(
          mappedBoard(
            criteria: [
              criterion(text: 'Changed', checkIds: ['Auto', 'Manual']),
            ],
          ).requirements.first,
          editing: true,
        );
        expect(copiedCriteria(store).single['checkSummary'], 'stale');
        controller.dispose();
      },
    );
  }

  testWidgets('editor adds, reopens and removes explicit criterion mappings', (
    tester,
  ) async {
    final records = Transactions();
    await RequirementsStore(records)
        .save('p', RequirementsBoard(), mappedBoard(criteria: []));
    await tester.pumpWidget(
      MaterialApp(
        home: RequirementsScreen(
          controller: RequirementsController('p', RequirementsStore(records)),
          projectName: 'Test',
        ),
      ),
    );
    await tester.tap(find.text('Edit R1'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add authored criterion'));
    await tester.tap(find.text('Add authored criterion'));
    await tester.pumpAndSettle();
    for (final entry in {
      'Criterion 1 ID': 'AC1',
      'Criterion 1 text': 'Exact restored item',
      'Criterion 1 check IDs (comma separated)': 'Auto',
    }.entries) {
      final field = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == entry.key,
      );
      await tester.ensureVisible(field);
      await tester.enterText(field, entry.value);
    }
    final ruleSwitch = find.widgetWithText(
      SwitchListTile,
      'Verify this criterion using all mapped named tests',
    );
    await tester.ensureVisible(ruleSwitch);
    await tester.tap(ruleSwitch);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      RequirementsStore(records)
          .load('p')
          .requirements
          .first
          .criteria
          .single
          .verificationRule,
      CriterionVerificationRule.allMappedNamedTests,
    );
    expect(
      RequirementsStore(records)
          .load('p')
          .requirements
          .first
          .criteria
          .single
          .checkIds,
      ['Auto'],
    );
    await tester.tap(find.text('Edit R1'));
    await tester.pumpAndSettle();
    expect(find.text('Exact restored item'), findsOneWidget);
    expect(
      tester
          .widget<SwitchListTile>(
            find.widgetWithText(
              SwitchListTile,
              'Verify this criterion using all mapped named tests',
            ),
          )
          .value,
      isTrue,
    );
    await tester.ensureVisible(find.text('Remove criterion 1'));
    await tester.tap(find.text('Remove criterion 1'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      RequirementsStore(records).load('p').requirements.first.criteria,
      isEmpty,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('narrow enlarged report shows explicit unmapped criterion', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = await fixture();
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: RequirementCheckReportScreen(
          controller: RequirementCheckReportController(
            project,
            RequirementCheckReportStore(records),
          ),
        ),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Unmapped criterion: no checks selected.'),
      200,
    );
    expect(find.text('Criterion acceptance: not verified'), findsWidgets);
    expect(find.text('Criterion checks: no mappings'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
