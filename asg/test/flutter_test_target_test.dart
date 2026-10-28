// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/controllers/requirements_controller.dart';
import 'package:asg/models/portable_export_redaction.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/requirement_check_report.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/views/requirements_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'board_mapped_build_plan_test.dart' show sharedBoard;
import 'requirement_check_report_test.dart' show Records, prepare, project;

const target = FlutterTestTarget(
  file: 'test/storage/saved_item_test.dart',
  name: 'storage preserves exact item [中文].*',
);
AcceptanceCheckDefinition declaration({
  FlutterTestTarget? selection = target,
}) => AcceptanceCheckDefinition(
  id: 'C1',
  type: AcceptanceCheckType.automated,
  expectation: 'Saved item survives reopening',
  target: selection,
);
RequirementsBoard board([FlutterTestTarget selection = target]) {
  final original = sharedBoard(done: true);
  return RequirementsBoard(
    revision: 1,
    requirements: [
      for (final r in original.requirements)
        ProjectRequirement(
          id: r.id,
          title: r.title,
          acceptance: r.acceptance,
          checks: [declaration(selection: selection)],
        ),
    ],
    tasks: original.tasks,
  );
}

void main() {
  test(
    'legacy encoding unchanged; literal targets survive archive and store',
    () async {
      final old = declaration(selection: null).toJson();
      expect(old.keys, ['id', 'type', 'expectation']);
      expect(AcceptanceCheckDefinition.fromJson(old).target, isNull);
      final records = Records();
      final store = RequirementsStore(records);
      final saved = await store.save('p', RequirementsBoard(), board());
      expect(store.load('p').toJson(), saved.toJson());
      final archive = PortableProjectArchive(requirements: saved, messages: []);
      expect(
        PortableProjectArchive.decode(archive.encode()).requirements.toJson(),
        saved.toJson(),
      );
      expect(saved.document('Test'), contains('exact name: ${target.name}'));
    },
  );
  test(
    'unsafe targets fail before persistence and malformed JSON is rejected',
    () async {
      final records = Records();
      final controller = RequirementsController('p', RequirementsStore(records))
        ..load();
      for (final file in [
        '../test/a_test.dart',
        '/test/a_test.dart',
        'test/../a_test.dart',
        'test/a.dart',
        'test/a_test.dart --help',
        'test/a\\b_test.dart',
        'test//a_test.dart',
        'test/.hidden_test.dart',
        'test/-option_test.dart',
        'test/a_test.dart\n',
      ]) {
        expect(
          await controller.saveRequirement(
            ProjectRequirement(
              id: 'R1',
              title: 'Title',
              acceptance: 'Accept',
              checks: [
                declaration(
                  selection: FlutterTestTarget(file: file, name: 'test'),
                ),
              ],
            ),
          ),
          isFalse,
          reason: file,
        );
        expect(records.data, isEmpty);
      }
      for (final name in ['', ' ', 'a\nb', 'a\u0000b', 'a' * 201]) {
        expect(
          () => FlutterTestTarget(file: target.file, name: name).validate(),
          throwsFormatException,
        );
      }
      for (final value in [
        null,
        {},
        {...target.toJson(), 'runner': 'shell'},
        {...target.toJson(), 'extra': true},
      ]) {
        expect(
          () => AcceptanceCheckDefinition.fromJson({
            ...declaration().toJson(),
            'target': value,
          }),
          throwsFormatException,
        );
      }
      for (final type in [
        AcceptanceCheckType.manual,
        AcceptanceCheckType.advisory,
      ]) {
        expect(
          () => AcceptanceCheckDefinition(
            id: 'C',
            type: type,
            expectation: 'Observe',
            target: target,
          ).validate(),
          throwsFormatException,
        );
      }
      controller.dispose();
    },
  );
  test(
    'target edits invalidate approval and remain missing direct evidence',
    () async {
      final records = Records();
      final saved = await prepare(records, board: board());
      await SourceGenerationStore(records).save('p', saved);
      final reports = RequirementCheckReportStore(records);
      final before = reports.load(project);
      final controller = RequirementsController('p', RequirementsStore(records))
        ..load();
      final changed = board(
        const FlutterTestTarget(
          file: 'test/other_test.dart',
          name: 'another literal test',
        ),
      ).requirements.first;
      expect(await controller.saveRequirement(changed, editing: true), isTrue);
      final after = reports.load(project);
      expect(after.savedInputsCurrent, isFalse);
      expect(after.results.first.state, RequirementCheckState.stale);
      expect(
        after.results.first.acceptance.requirementSha256,
        isNot(before.results.first.acceptance.requirementSha256),
      );
      final evidence = jsonDecode(
        after.evidenceJson,
      )['requirements'][0]['acceptanceEvidence'];
      expect(evidence['status'], 'unverified');
      expect(evidence['declaredChecks'][0]['status'], 'missing');
      expect(
        evidence['declaredChecks'][0]['target']['name'],
        'another literal test',
      );
      expect(evidence['directChecks'], isEmpty);
      controller.dispose();
    },
  );
  test(
    'redaction drops changed selectors and retains unaffected selectors',
    () {
      final archive = PortableProjectArchive(
        requirements: board(),
        messages: [],
      );
      for (final text in ['storage', '中文', 'saved_item']) {
        final redacted = PortableExportRedaction.apply(archive, text);
        expect(
          redacted.archive.requirements.requirements.first.checks.first.target,
          isNull,
        );
        expect(redacted.matches, greaterThan(0));
        expect(redacted.archive.encode(), isNot(contains(text)));
      }
      final retained = PortableExportRedaction.apply(archive, 'Saved');
      expect(
        retained.archive.requirements.requirements.first.checks.first.target!
            .toJson(),
        target.toJson(),
      );
    },
  );
  testWidgets('editor saves, reopens and removes a literal target', (
    tester,
  ) async {
    final records = Records();
    await RequirementsStore(records).save('p', RequirementsBoard(), board());
    final controller = RequirementsController('p', RequirementsStore(records));
    await tester.pumpWidget(
      MaterialApp(
        home: RequirementsScreen(controller: controller, projectName: 'Test'),
      ),
    );
    final id = board().requirements.first.id;
    await tester.tap(find.text('Edit $id'));
    await tester.pumpAndSettle();
    final name = find.widgetWithText(TextField, 'Exact test name');
    await tester.ensureVisible(name);
    await tester.enterText(name, ' full literal name .* ');
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      RequirementsStore(records)
          .load('p')
          .requirements
          .first
          .checks
          .first
          .target!
          .name,
      ' full literal name .* ',
    );
    await tester.tap(find.text('Edit $id'));
    await tester.pumpAndSettle();
    expect(find.text(' full literal name .* '), findsOneWidget);
    final toggle = find.widgetWithText(
      SwitchListTile,
      'Map an exact Flutter test',
    );
    await tester.ensureVisible(toggle);
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.widgetWithText(FilledButton, 'Save'));
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(
      RequirementsStore(records)
          .load('p')
          .requirements
          .first
          .checks
          .first
          .target,
      isNull,
    );
    expect(tester.takeException(), isNull);
  });
}
