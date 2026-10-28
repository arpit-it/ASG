// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/models/named_check_observation.dart';
import 'package:asg/models/named_flutter_test_result.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/named_check_observation_store.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:asg/controllers/requirement_check_report_controller.dart';
import 'package:asg/views/requirement_check_report_screen.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'board_mapped_build_plan_test.dart' show sharedBoard;
import 'manual_check_observation_test.dart' show Transactions;
import 'requirement_check_report_test.dart' show prepare, project;

const target = FlutterTestTarget(file: 'test/app_test.dart', name: 'opens app');
NamedFlutterTestResult result(
  bool passed, {
  FlutterTestTarget selected = target,
}) => NamedFlutterTestResult.fromCommand({
  'exitCode': passed ? 0 : 1,
  'timedOut': false,
  'cancelled': false,
  'outputLimitExceeded': false,
  'output': 'PRIVATE_OUTPUT',
  'targetedTest': {
    'file': selected.file,
    'name': selected.name,
    'status': passed ? 'passed' : 'notPassed',
    'reason': passed ? 'executedExactTest' : 'commandFailed',
  },
}, selected);

Future<Transactions> fixture() async {
  final records = Transactions();
  final original = sharedBoard(done: true);
  final first = original.requirements.first;
  final saved = await prepare(
    records,
    board: RequirementsBoard(
      requirements: [
        ProjectRequirement(
          id: first.id,
          title: first.title,
          acceptance: first.acceptance,
          checks: const [
            AcceptanceCheckDefinition(
              id: 'Auto',
              type: AcceptanceCheckType.automated,
              expectation: 'Opens the app',
              target: target,
            ),
            AcceptanceCheckDefinition(
              id: 'Manual',
              type: AcceptanceCheckType.manual,
              expectation: 'Observe app',
            ),
          ],
        ),
        ...original.requirements.skip(1),
      ],
      tasks: original.tasks,
    ),
  );
  await SourceGenerationStore(records).save('p', saved);
  return records;
}

Future<void> record(
  RequirementCheckReportStore store,
  bool passed, {
  bool Function()? authorized,
}) {
  final report = store.load(project);
  return store.recordNamedTestResult(
    project,
    report,
    report.results.first.requirement.id,
    'Auto',
    result(passed),
    DateTime.utc(2026, 10, 28),
    authorized: authorized ?? () => true,
  );
}

void main() {
  for (final passed in [true, false]) {
    testWidgets(
      'report displays saved named outcome $passed and stale run honestly',
      (tester) async {
        final records = await fixture();
        final store = RequirementCheckReportStore(records);
        await record(store, passed);
        final controller = RequirementCheckReportController(project, store);
        await tester.pumpWidget(
          MaterialApp(
            home: RequirementCheckReportScreen(controller: controller),
          ),
        );
        await tester.scrollUntilVisible(
          find.text('Declared check Auto (automated)'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        expect(
          find.text(
            'Saved named-test result: ${passed ? "passed" : "not passed"}',
          ),
          findsOneWidget,
        );
        expect(find.textContaining('Not executed.'), findsNothing);
        expect(find.textContaining('PRIVATE_OUTPUT'), findsNothing);
        expect(find.text('Acceptance criteria: not verified'), findsWidgets);
        expect(
          find.text('Missing direct result; acceptance remains unverified.'),
          findsOneWidget,
        );
        final json = jsonDecode(records.data['studio.generation.v1.p']!);
        json['sources']['lib/main.dart'] = 'c' * 64;
        records.data['studio.generation.v1.p'] = jsonEncode(json);
        controller.load();
        await tester.pump();
        expect(
          find.text(
            'Stale saved named-test result: ${passed ? "passed" : "not passed"}',
          ),
          findsOneWidget,
        );
        expect(
          find.text(
            'Saved named-test result: ${passed ? "passed" : "not passed"}',
          ),
          findsNothing,
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets('missing automated evidence is never displayed as a saved pass', (
    tester,
  ) async {
    final records = await fixture();
    final controller = RequirementCheckReportController(
      project,
      RequirementCheckReportStore(records),
    );
    await tester.pumpWidget(
      MaterialApp(home: RequirementCheckReportScreen(controller: controller)),
    );
    await tester.scrollUntilVisible(
      find.text('Declared check Auto (automated)'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      find.text('Missing direct result; acceptance remains unverified.'),
      findsNWidgets(2),
    );
    expect(find.textContaining('named-test result:'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test('pass/fail replaces only the authored check and exports sanitized saved binding', () async {
    final records = await fixture();
    final store = RequirementCheckReportStore(records);
    for (final passed in [true, false]) {
      await record(store, passed);
      final report = RequirementCheckReportStore(records).load(project);
      final value = report.namedObservations.single;
      expect(value.result.passed, passed);
      expect(value.runSha256, report.revisionIdentity!.savedRunSha256);
      expect(
        value.requirementSha256,
        report.results.first.acceptance.requirementSha256,
      );
      expect(report.namedObservationCurrent(value), isTrue);
      final json = jsonDecode(report.evidenceJson);
      expect(
        json['namedObservations'].single['status'],
        passed ? 'savedTargetPassed' : 'savedTargetNotPassed',
      );
      expect(json['requirements'].first['acceptanceStatus'], 'unverified');
      expect(jsonEncode(value.toJson()), isNot(contains('PRIVATE')));
      expect(() => report.namedObservations.clear(), throwsUnsupportedError);
    }
  });

  test(
    'unknown, manual and wrong literal targets cannot acquire a binding',
    () async {
      final records = await fixture();
      final store = RequirementCheckReportStore(records);
      final report = store.load(project);
      for (final id in ['Unknown', 'Manual', 'Auto']) {
        await expectLater(
          store.recordNamedTestResult(
            project,
            report,
            report.results.first.requirement.id,
            id,
            result(
              true,
              selected: const FlutterTestTarget(
                file: 'test/other_test.dart',
                name: 'other',
              ),
            ),
            DateTime.now(),
            authorized: () => true,
          ),
          throwsStateError,
        );
      }
      expect(
        records.data.containsKey(NamedCheckObservationStore.key('p')),
        isFalse,
      );
    },
  );

  test(
    'changed requirement/source/approval and failed runs stale saved evidence',
    () async {
      for (final change in ['requirement', 'source', 'approval', 'failed']) {
        final records = await fixture();
        final store = RequirementCheckReportStore(records);
        await record(store, true);
        final selected = store.load(project);
        final key = switch (change) {
          'requirement' => 'studio.requirements.v1.p',
          'approval' => 'studio.planApproval.v1.p',
          _ => 'studio.generation.v1.p',
        };
        final json = jsonDecode(records.data[key]!);
        if (change == 'requirement') {
          json['requirements'][0]['title'] = 'Edited';
        } else if (change == 'approval') {
          json['approved'] = false;
        } else if (change == 'source') {
          json['sources']['lib/main.dart'] = 'c' * 64;
        } else {
          json['phase'] = 'failed';
        }
        records.data[key] = jsonEncode(json);
        final changed = store.load(project);
        expect(
          changed.namedObservationCurrent(changed.namedObservations.single),
          isFalse,
          reason: change,
        );
        expect(
          jsonDecode(
            changed.evidenceJson,
          )['namedObservations'].single['status'],
          'stale',
        );
        await expectLater(
          store.recordNamedTestResult(
            project,
            selected,
            selected.results.first.requirement.id,
            'Auto',
            result(false),
            DateTime.now(),
            authorized: () => true,
          ),
          throwsStateError,
        );
      }
    },
  );

  test('storage failure, revoked authorization and concurrent edits preserve prior bytes', () async {
    for (final change in [
      'storage',
      'authorization',
      'input',
      'named',
      'manual',
    ]) {
      final records = await fixture();
      final store = RequirementCheckReportStore(records);
      await record(store, true);
      final before = records.data[NamedCheckObservationStore.key('p')];
      if (change == 'storage') records.fail = true;
      if (change == 'input') {
        records.beforeCommit = () =>
            records.data['studio.application.v1.p'] = '{}';
      }
      if (change == 'manual') {
        records.beforeCommit = () =>
            records.data['studio.manualChecks.v1.p'] = '{}';
      }
      if (change == 'named') {
        records.beforeCommit = () =>
            records.data[NamedCheckObservationStore.key('p')] = '{}';
      }
      await expectLater(
        record(store, false, authorized: () => change != 'authorization'),
        throwsStateError,
      );
      expect(
        records.data[NamedCheckObservationStore.key('p')],
        change == 'named' ? '{}' : before,
      );
    }
  });

  test('strict records reject corrupt timestamps, fields, duplicates and contradictory outcomes', () async {
    final records = await fixture();
    final store = RequirementCheckReportStore(records);
    await record(store, true);
    final value = store.load(project).namedObservations.single.toJson();
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (v) => v['observedAt'] = '2026-02-30T00:00:00.000Z',
      (v) => v['observedAt'] = '2026-10-28T00:00:00.000+00:00',
      (v) => v['runSha256'] = 'invalid',
      (v) => v['checkId'] = 'invalid id',
      (v) => v['extra'] = true,
      (v) => v['result']['output'] = 'PRIVATE_OUTPUT',
      (v) => v['result']['exitCode'] = 1,
      (v) => v['target']['name'] = 'different',
      (v) => v['result']['cancelled'] = true,
    ]) {
      final changed = jsonDecode(jsonEncode(value)) as Map<String, dynamic>;
      mutate(changed);
      expect(
        () => NamedCheckObservation.fromJson(changed),
        throwsFormatException,
      );
    }
    final raw = jsonEncode({
      'version': 1,
      'observations': [value, value],
    });
    records.data[NamedCheckObservationStore.key('p')] = raw;
    expect(() => store.load(project), throwsFormatException);
    expect(records.data[NamedCheckObservationStore.key('p')], raw);
  });

  test('native database reopens direct evidence and isolates corruption without replacement', () async {
    final source = await fixture();
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final directory = await Directory.systemTemp.createTemp(
      'asg_named_records_',
    );
    final path = '${directory.path}/records.db';
    var native = await databaseFactoryIo.openDatabase(path);
    try {
      var database = await StudioDatabase.migrate(native, preferences);
      for (final entry in source.data.entries) {
        await database.setString(entry.key, entry.value);
      }
      await record(RequirementCheckReportStore(database), true);
      await native.close();
      native = await databaseFactoryIo.openDatabase(path);
      database = await StudioDatabase.migrate(native, preferences);
      final report = RequirementCheckReportStore(database).load(project);
      expect(
        report.namedObservationCurrent(report.namedObservations.single),
        isTrue,
      );
      await StoreRef<String, String>('records')
          .record(NamedCheckObservationStore.key('p'))
          .put(native, '{corrupt');
      await native.close();
      native = await databaseFactoryIo.openDatabase(path);
      database = await StudioDatabase.migrate(native, preferences);
      expect(
        () => RequirementCheckReportStore(database).load(project),
        throwsFormatException,
      );
      expect(database.getString('studio.projects.v1'), isNotNull);
      expect(
        await StoreRef<String, String>('records')
            .record(NamedCheckObservationStore.key('p'))
            .get(native),
        '{corrupt',
      );
    } finally {
      await native.close();
      await directory.delete(recursive: true);
    }
  });
}
