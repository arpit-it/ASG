// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:asg/controllers/requirements_controller.dart';
import 'package:asg/models/portable_export_redaction.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/requirement_check_report.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/portable_requirements_store.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/views/requirements_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'board_mapped_build_plan_test.dart' show sharedBoard;
import 'requirement_check_report_test.dart' show Records, prepare, project;

const checks = [
  AcceptanceCheckDefinition(
    id: 'C1',
    type: AcceptanceCheckType.automated,
    expectation: 'saved_item_test: exact saved 中文 item appears after reopening',
  ),
  AcceptanceCheckDefinition(
    id: 'C2',
    type: AcceptanceCheckType.manual,
    expectation: 'Observe keyboard focus after reopening',
  ),
  AcceptanceCheckDefinition(
    id: 'C3',
    type: AcceptanceCheckType.advisory,
    expectation: 'Review accessibility suggestions',
  ),
];
ProjectRequirement requirement([
  List<AcceptanceCheckDefinition> values = checks,
]) => ProjectRequirement(
  id: 'R1',
  title: 'Save',
  acceptance: 'Retain exact item',
  checks: values,
);
void main() {
  test('legacy identity unchanged; declarations survive store, archive and redaction', () async {
    final legacy = requirement([]);
    expect(legacy.toJson().keys, ['id', 'title', 'acceptance']);
    expect(ProjectRequirement.fromJson(legacy.toJson()).checks, isEmpty);
    final records = Records();
    final saved = await RequirementsStore(records).save(
      'p',
      RequirementsBoard(),
      RequirementsBoard(requirements: [requirement()]),
    );
    final reopened = PortableRequirementsStore(records).load('p');
    expect(reopened.toJson(), saved.toJson());
    final archive = PortableProjectArchive(
      requirements: reopened,
      messages: [],
    );
    expect(
      PortableProjectArchive.decode(archive.encode()).requirements.toJson(),
      saved.toJson(),
    );
    final redacted = PortableExportRedaction.apply(archive, '中文').archive;
    expect(
      redacted.requirements.requirements.single.checks.first.expectation,
      contains('[redacted]'),
    );
    expect(
      redacted.requirements.requirements.single.checks.map((c) => c.type),
      AcceptanceCheckType.values,
    );
    expect(saved.document('Project'), contains('Check C1 (automated)'));
    expect(saved.document('Project'), contains('no direct result recorded'));
  });
  test('invalid mappings and duplicates fail before persistence', () async {
    final invalid = [
      [checks.first, checks.first],
      [
        const AcceptanceCheckDefinition(
          id: '../C',
          type: AcceptanceCheckType.manual,
          expectation: 'observe',
        ),
      ],
      [
        const AcceptanceCheckDefinition(
          id: 'C',
          type: AcceptanceCheckType.manual,
          expectation: ' ',
        ),
      ],
      [
        AcceptanceCheckDefinition(
          id: 'C',
          type: AcceptanceCheckType.manual,
          expectation: 'x' * 501,
        ),
      ],
      List.generate(
        11,
        (i) => AcceptanceCheckDefinition(
          id: 'C$i',
          type: AcceptanceCheckType.automated,
          expectation: 'observe',
        ),
      ),
    ];
    final records = Records();
    for (final values in invalid) {
      final controller = RequirementsController('p', RequirementsStore(records))
        ..load();
      expect(await controller.saveRequirement(requirement(values)), isFalse);
      expect(records.data, isEmpty);
      expect(controller.error, isNotNull);
      controller.dispose();
    }
    expect(
      () => AcceptanceCheckDefinition.fromJson({
        'id': 'C',
        'type': 'unknown',
        'expectation': 'value',
      }),
      throwsArgumentError,
    );
    expect(
      () => AcceptanceCheckDefinition.fromJson({
        'id': 'C',
        'type': 'manual',
        'expectation': 'value',
        'extra': true,
      }),
      throwsFormatException,
    );
  });
  test(
    'declaration edits invalidate exact identity, approval and manual progress',
    () async {
      final records = Records();
      final saved = await prepare(records);
      await SourceGenerationStore(records).save('p', saved);
      final store = RequirementCheckReportStore(records);
      final before = store.load(project);
      final original = before.results.first.requirement;
      final controller = RequirementsController('p', RequirementsStore(records))
        ..load();
      expect(
        await controller.saveRequirement(
          ProjectRequirement(
            id: original.id,
            title: original.title,
            acceptance: original.acceptance,
            checks: checks,
          ),
          editing: true,
        ),
        isTrue,
      );
      final after = store.load(project);
      expect(
        after.results.first.acceptance.requirementSha256,
        isNot(before.results.first.acceptance.requirementSha256),
      );
      expect(after.results.first.state, RequirementCheckState.stale);
      expect(
        controller.board!.tasks
            .where((t) => t.requirementId == original.id)
            .every((t) => t.status == TaskStatus.queued),
        isTrue,
      );
      final evidence = jsonDecode(
        after.evidenceJson,
      )['requirements'][0]['acceptanceEvidence'];
      expect(evidence['status'], 'unverified');
      expect(evidence['directChecks'], isEmpty);
      expect(evidence['declaredChecks'], hasLength(3));
      expect(
        evidence['declaredChecks'].every(
          (dynamic c) => c['status'] == 'missing' && c['result'] == null,
        ),
        isTrue,
      );
      controller.dispose();
    },
  );
  test(
    'generic passing operations do not satisfy declared acceptance checks',
    () async {
      final records = Records();
      final original = sharedBoard(done: true);
      final mapped = RequirementsBoard(
        requirements: [
          for (final r in original.requirements)
            ProjectRequirement(
              id: r.id,
              title: r.title,
              acceptance: r.acceptance,
              checks: checks,
            ),
        ],
        tasks: original.tasks,
      );
      final saved = await prepare(records, board: mapped);
      await SourceGenerationStore(records).save('p', saved);
      final report = RequirementCheckReportStore(records).load(project);
      expect(
        report.results.first.state,
        RequirementCheckState.mappedChecksPassed,
      );
      final evidence = report.results.first.acceptance.toJson();
      expect(evidence['status'], 'unverified');
      expect(evidence['directChecks'], isEmpty);
      expect(
        (evidence['declaredChecks'] as List).every(
          (dynamic c) => c['status'] == 'missing',
        ),
        isTrue,
      );
    },
  );
  test('malformed optional declarations are never silently discarded', () {
    for (final value in [null, 'invalid', {}]) {
      expect(
        () => ProjectRequirement.fromJson({
          ...requirement([]).toJson(),
          'checks': value,
        }),
        throwsFormatException,
      );
    }
  });
  testWidgets('editor preserves mappings and removes one check', (
    tester,
  ) async {
    final records = Records();
    await RequirementsStore(records).save(
      'p',
      RequirementsBoard(),
      RequirementsBoard(requirements: [requirement()]),
    );
    final controller = RequirementsController('p', RequirementsStore(records));
    await tester.pumpWidget(
      MaterialApp(
        home: RequirementsScreen(controller: controller, projectName: 'Test'),
      ),
    );
    await tester.tap(find.text('Edit R1'));
    await tester.pumpAndSettle();
    expect(find.text(checks.first.expectation), findsOneWidget);
    final remove = find.text('Remove check 1');
    await tester.ensureVisible(remove);
    await tester.tap(remove);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      RequirementsStore(records)
          .load('p')
          .requirements
          .single
          .checks
          .map((c) => c.id),
      ['C2', 'C3'],
    );
    await tester.tap(find.text('Edit R1'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Add acceptance check'));
    await tester.tap(find.text('Add acceptance check'));
    await tester.pumpAndSettle();
    final id = find.byWidgetPredicate(
      (w) => w is TextField && w.decoration?.labelText == 'Check 3 ID',
    );
    await tester.ensureVisible(id);
    await tester.enterText(id, 'C4');
    final outcome = find
        .widgetWithText(TextField, 'Expected observable outcome')
        .last;
    await tester.ensureVisible(outcome);
    await tester.enterText(outcome, 'Observe the exact restored item');
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      RequirementsStore(records).load('p').requirements.single.checks.last.id,
      'C4',
    );
    expect(tester.takeException(), isNull);
  });
}
