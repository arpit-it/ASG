// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/controllers/requirements_controller.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/portable_export_redaction.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:asg/controllers/requirement_check_report_controller.dart';
import 'package:asg/views/requirement_check_report_screen.dart';

import 'acceptance_criterion_mapping_test.dart' as mapping;
import 'named_check_observation_test.dart' as named;
import 'manual_check_observation_test.dart' show Transactions;
import 'requirement_check_report_test.dart' show prepare, project;

AcceptanceCriterionDefinition rule({
  List<String> ids = const ['Auto'],
  String text = 'Authored contract',
}) => AcceptanceCriterionDefinition(
  id: 'AC1',
  text: text,
  checkIds: ids,
  verificationRule: CriterionVerificationRule.allMappedNamedTests,
);

void main() {
  test(
    'legacy default, strict decoding, archive and redaction preserve rule',
    () {
      final legacy = mapping.criterion();
      expect(legacy.toJson().containsKey('verificationRule'), isFalse);
      expect(
        AcceptanceCriterionDefinition.fromJson(legacy.toJson())
            .verificationRule,
        CriterionVerificationRule.none,
      );
      for (final value in [null, true, 'unknown']) {
        expect(
          () => AcceptanceCriterionDefinition.fromJson({
            ...legacy.toJson(),
            'verificationRule': value,
          }),
          throwsFormatException,
        );
      }
      final board = mapping.mappedBoard(criteria: [rule(text: 'secret')]);
      final archive = PortableProjectArchive(
        requirements: RequirementsBoard(
          revision: 1,
          requirements: board.requirements,
          tasks: board.tasks,
        ),
        messages: [],
      );
      final decoded = PortableProjectArchive.decode(archive.encode());
      expect(
        decoded
            .requirements
            .requirements
            .first
            .criteria
            .single
            .verificationRule,
        CriterionVerificationRule.allMappedNamedTests,
      );
      final redacted = PortableExportRedaction.apply(decoded, 'secret').archive;
      expect(
        redacted
            .requirements
            .requirements
            .first
            .criteria
            .single
            .verificationRule,
        CriterionVerificationRule.allMappedNamedTests,
      );
      expect(
        redacted.requirements.requirements.first.criteria.single.text,
        '[redacted]',
      );
    },
  );

  test('invalid named-test rules fail before writes', () async {
    final records = Transactions();
    final store = RequirementsStore(records);
    final saved = await store.save(
      'p',
      RequirementsBoard(),
      mapping.mappedBoard(),
    );
    final before = Map.of(records.data);
    for (final ids in <List<String>>[
      [],
      ['Manual'],
      ['Advice'],
      ['Auto', 'Manual'],
      ['Unknown'],
    ]) {
      await expectLater(
        store.save('p', saved, mapping.mappedBoard(criteria: [rule(ids: ids)])),
        throwsFormatException,
      );
      expect(records.data, before);
    }
  });

  for (final passed in [true, false]) {
    test(
      'explicit rule needs exact saved pass=$passed and survives reopen',
      () async {
        final records = Transactions();
        final saved = await prepare(
          records,
          board: mapping.mappedBoard(criteria: [rule()]),
        );
        await SourceGenerationStore(records).save('p', saved);
        final store = RequirementCheckReportStore(records);
        expect(mapping.copiedCriteria(store).single['status'], 'unverified');
        await named.record(store, passed);
        final row = mapping.copiedCriteria(store).single;
        expect(
          row['status'],
          passed ? 'verifiedAgainstAuthoredChecks' : 'unverified',
        );
        expect(row['requirementSha256'], matches(RegExp(r'^[a-f0-9]{64}$')));
        expect(
          row['savedRunSha256'],
          store.load(project).revisionIdentity!.savedRunSha256,
        );
        final reopened = Transactions()..data.addAll(records.data);
        expect(mapping.copiedCriteria(RequirementCheckReportStore(reopened)), [
          row,
        ]);
        final evidence = jsonDecode(
          store.load(project).evidenceJson,
        )['requirements'][0]['acceptanceEvidence'];
        expect(evidence['status'], 'unverified');
        expect(
          evidence['authoredContract']['status'],
          passed ? 'verifiedAgainstAuthoredChecks' : 'unverified',
        );
        expect(
          evidence['authoredContract']['unverifiedCriterionIds'],
          passed ? isEmpty : ['AC1'],
        );
        expect(
          evidence['authoredContract']['savedRunSha256'],
          row['savedRunSha256'],
        );
        expect(
          evidence['authoredContract']['requirementSha256'],
          row['requirementSha256'],
        );
        expect(
          store
              .load(project)
              .requirementVerifiedAgainstChecks(
                store.load(project).results.first.requirement,
              ),
          passed,
        );
        final controller = RequirementsController(
          'p',
          RequirementsStore(records),
        )..load();
        await controller.saveRequirement(
          mapping
              .mappedBoard(criteria: [rule(text: 'Edited contract')])
              .requirements
              .first,
          editing: true,
        );
        expect(mapping.copiedCriteria(store).single['status'], 'unverified');
        expect(mapping.copiedCriteria(store).single['checkSummary'], 'stale');
        final stale = store.load(project);
        expect(
          stale.requirementVerifiedAgainstChecks(
            stale.results.first.requirement,
          ),
          isFalse,
        );
        controller.dispose();
      },
    );
  }

  test(
    'criterion verdict rejects content outside the report snapshot',
    () async {
      final records = Transactions();
      final saved = await prepare(
        records,
        board: mapping.mappedBoard(criteria: [rule()]),
      );
      await SourceGenerationStore(records).save('p', saved);
      final store = RequirementCheckReportStore(records);
      await named.record(store, true);
      final report = store.load(project);
      final requirement = report.results.first.requirement;
      expect(
        report.criterionVerifiedAgainstChecks(requirement, rule()),
        isTrue,
      );
      for (final detached in [
        rule(text: 'Changed acceptance'),
        AcceptanceCriterionDefinition(
          id: 'Unauthored',
          text: rule().text,
          checkIds: ['Auto'],
          verificationRule: CriterionVerificationRule.allMappedNamedTests,
        ),
      ]) {
        expect(
          report.criterionVerifiedAgainstChecks(requirement, detached),
          isFalse,
        );
        expect(
          report.criterionEvidence(requirement, detached)['status'],
          'unverified',
        );
      }
      final changed = mapping
          .mappedBoard(criteria: [rule(text: 'Changed acceptance')])
          .requirements
          .first;
      expect(
        report.criterionVerifiedAgainstChecks(changed, changed.criteria.single),
        isFalse,
      );
    },
  );

  test(
    'adding opt-in rule invalidates previously passed mapping evidence',
    () async {
      final records = await mapping.fixture();
      final store = RequirementCheckReportStore(records);
      await named.record(store, true);
      expect(
        mapping.copiedCriteria(store).first['checkSummary'],
        'automatedChecksPassed',
      );
      expect(mapping.copiedCriteria(store).first['status'], 'unverified');
      final controller = RequirementsController('p', RequirementsStore(records))
        ..load();
      await controller.saveRequirement(
        mapping
            .mappedBoard(criteria: [rule(text: mapping.criterion().text)])
            .requirements
            .first,
        editing: true,
      );
      expect(mapping.copiedCriteria(store).first['status'], 'unverified');
      expect(mapping.copiedCriteria(store).first['checkSummary'], 'stale');
      controller.dispose();
    },
  );
  test(
    'all explicit criteria pass together and survive durable reopen',
    () async {
      final records = Transactions();
      final saved = await prepare(
        records,
        board: mapping.mappedBoard(
          criteria: [
            rule(),
            AcceptanceCriterionDefinition(
              id: 'AC2',
              text: 'Second authored contract',
              checkIds: ['Auto'],
              verificationRule: CriterionVerificationRule.allMappedNamedTests,
            ),
          ],
        ),
      );
      await SourceGenerationStore(records).save('p', saved);
      final store = RequirementCheckReportStore(records);
      await named.record(store, true);
      final reopened = Transactions()..data.addAll(records.data);
      final report = RequirementCheckReportStore(reopened).load(project);
      expect(
        report.requirementVerifiedAgainstChecks(
          report.results.first.requirement,
        ),
        isTrue,
      );
      final evidence = jsonDecode(
        report.evidenceJson,
      )['requirements'][0]['acceptanceEvidence'];
      expect(evidence['authoredContract']['criterionIds'], ['AC1', 'AC2']);
      expect(evidence['authoredContract']['unverifiedCriterionIds'], isEmpty);
      expect(evidence['status'], 'unverified');
      expect(report.evidenceJson, isNot(contains('PRIVATE_OUTPUT')));
      await named.record(store, false);
      final failed = store.load(project);
      expect(
        failed.requirementVerifiedAgainstChecks(
          failed.results.first.requirement,
        ),
        isFalse,
      );
    },
  );

  for (final criteria in <List<AcceptanceCriterionDefinition>>[
    [],
    [mapping.criterion()],
    [rule(), mapping.criterion(id: 'AC2', checkIds: [])],
    [
      rule(),
      mapping.criterion(id: 'AC2', checkIds: ['Manual']),
    ],
    [
      rule(),
      mapping.criterion(id: 'AC2', checkIds: ['Advice']),
    ],
    [rule(), mapping.criterion(id: 'AC2')],
  ]) {
    test(
      'whole contract refuses empty/default/mixed criteria ${criteria.map((c) => c.toJson())}',
      () async {
        final records = Transactions();
        final saved = await prepare(
          records,
          board: mapping.mappedBoard(criteria: criteria),
        );
        await SourceGenerationStore(records).save('p', saved);
        final store = RequirementCheckReportStore(records);
        await named.record(store, true);
        final report = store.load(project);
        expect(
          report.requirementVerifiedAgainstChecks(
            report.results.first.requirement,
          ),
          isFalse,
        );
        final evidence = jsonDecode(
          report.evidenceJson,
        )['requirements'][0]['acceptanceEvidence'];
        expect(evidence['authoredContract']['status'], 'unverified');
        expect(evidence['status'], 'unverified');
      },
    );
  }

  testWidgets('bounded saved-rule verdict visible at narrow doubled text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = Transactions();
    final saved = await prepare(
      records,
      board: mapping.mappedBoard(criteria: [rule()]),
    );
    await SourceGenerationStore(records).save('p', saved);
    final store = RequirementCheckReportStore(records);
    await named.record(store, true);
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
      find.text(
        'Requirement contract: verified against all authored named-test rules at saved revision',
      ),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text(
        'Criterion rule: verified against authored named tests at saved revision',
      ),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text(
        'Criterion rule: verified against authored named tests at saved revision',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
