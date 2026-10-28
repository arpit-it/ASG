// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:asg/controllers/requirement_check_report_controller.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/manual_check_observation.dart';
import 'package:asg/services/manual_check_observation_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/views/requirement_check_report_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'requirement_check_report_test.dart' show Records, prepare, project;
import 'board_mapped_build_plan_test.dart' show sharedBoard;

class Transactions extends Records implements ConditionalRecordStorage {
  bool fail = false;
  Completer<void>? gate;
  void Function()? beforeCommit;
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    if (gate != null) await gate!.future;
    beforeCommit?.call();
    for (final entry in expected.entries) {
      if (data[entry.key] != entry.value) throw StateError('Changed');
    }
    if (fail) throw StateError('Unavailable');
    authorize();
    for (final entry in updates.entries) {
      StudioDatabase.validate(entry.key, entry.value);
    }
    data.addAll(updates);
  }
}

Future<Transactions> fixture() async {
  final records = Transactions();
  final original = sharedBoard(done: true);
  final first = original.requirements.first;
  final board = RequirementsBoard(
    requirements: [
      ProjectRequirement(
        id: first.id,
        title: first.title,
        acceptance: first.acceptance,
        checks: const [
          AcceptanceCheckDefinition(
            id: 'Observe',
            type: AcceptanceCheckType.manual,
            expectation: 'Observe keyboard navigation',
          ),
          AcceptanceCheckDefinition(
            id: 'Auto',
            type: AcceptanceCheckType.automated,
            expectation: 'Run targeted test',
          ),
        ],
      ),
      ...original.requirements.skip(1),
    ],
    tasks: original.tasks,
  );
  final saved = await prepare(records, board: board);
  await SourceGenerationStore(records).save('p', saved);
  return records;
}

Future<void> record(RequirementCheckReportStore store, bool passed) {
  final report = store.load(project);
  return store.recordManualObservation(
    project,
    report,
    report.results.first.requirement.id,
    'Observe',
    passed,
    DateTime.utc(2026, 10, 28),
    authorized: () => true,
  );
}

void main() {
  test(
    'observation timestamps reject normalized calendar and clock values',
    () {
      final valid = ManualCheckObservation(
        requirementId: 'R1',
        checkId: 'Observe',
        requirementSha256: 'a' * 64,
        runSha256: 'b' * 64,
        passed: true,
        observedAt: DateTime.utc(2024, 2, 29),
      ).toJson();
      for (final timestamp in [
        '2026-02-30T00:00:00.000Z',
        '2026-02-29T00:00:00.000Z',
        '2026-00-28T00:00:00.000Z',
        '2026-13-28T00:00:00.000Z',
        '2026-10-00T00:00:00.000Z',
        '2026-10-28T25:00:00.000Z',
        '2026-10-28T00:60:00.000Z',
        '2026-10-28T00:00:60.000Z',
        '2026-10-28T00:00:00.1234567Z',
        '20261028T000000Z',
        '2026-10-28 00:00:00.000Z',
      ]) {
        expect(
          () => ManualCheckObservation.fromJson({
            ...valid,
            'observedAt': timestamp,
          }),
          throwsFormatException,
          reason: timestamp,
        );
      }
      for (final timestamp in [
        '2024-02-29T00:00:00Z',
        '2024-02-29T23:59:59.123Z',
        '2024-02-29T23:59:59.123456Z',
      ]) {
        final observation = ManualCheckObservation.fromJson({
          ...valid,
          'observedAt': timestamp,
        });
        expect(observation.observedAt, DateTime.parse(timestamp));
        expect(
          ManualCheckObservation.fromJson(observation.toJson()).observedAt,
          observation.observedAt,
        );
      }
    },
  );

  test(
    'invalid saved timestamp clears reports without replacing corrupt bytes',
    () async {
      final records = await fixture();
      final store = RequirementCheckReportStore(records);
      await record(store, true);
      final selected = store.load(project);
      final controller = RequirementCheckReportController(project, store)
        ..load();
      final key = ManualCheckObservationStore.key('p');
      final json = jsonDecode(records.data[key]!) as Map<String, dynamic>;
      (json['observations'] as List).single['observedAt'] =
          '2026-02-30T00:00:00.000Z';
      final corrupt = jsonEncode(json);
      records.data[key] = corrupt;
      controller.load();
      expect(controller.report, isNull);
      expect(controller.error, isNotNull);
      await expectLater(
        store.recordManualObservation(
          project,
          selected,
          selected.results.first.requirement.id,
          'Observe',
          false,
          DateTime.now(),
          authorized: () => true,
        ),
        throwsFormatException,
      );
      expect(records.data[key], corrupt);
      controller.dispose();
    },
  );

  test('explicit manual pass/fail survives reload with exact identity; never verifies acceptance', () async {
    final records = await fixture();
    final store = RequirementCheckReportStore(records);
    await record(store, true);
    var report = RequirementCheckReportStore(records).load(project);
    final observation = report.manualObservations.single;
    expect(observation.passed, isTrue);
    expect(
      observation.requirementSha256,
      report.results.first.acceptance.requirementSha256,
    );
    expect(observation.runSha256, report.revisionIdentity!.savedRunSha256);
    expect(report.observationCurrent(observation), isTrue);
    final copied = jsonDecode(report.evidenceJson) as Map;
    expect(
      copied['manualObservations'].single['status'],
      'manuallyReportedPassed',
    );
    expect(copied['requirements'].first['acceptanceStatus'], 'unverified');
    await record(store, false);
    report = store.load(project);
    expect(report.manualObservations, hasLength(1));
    expect(report.manualObservations.single.passed, isFalse);
    expect(
      jsonDecode(report.evidenceJson)['manualObservations'].single['status'],
      'manuallyReportedFailed',
    );
  });

  test(
    'requirement edits stale observations and reject stale screen',
    () async {
      final records = await fixture();
      final store = RequirementCheckReportStore(records);
      await record(store, true);
      final selected = store.load(project);
      final requirements = RequirementsStore(records);
      final board = requirements.load('p');
      await requirements.save(
        'p',
        board,
        RequirementsBoard(
          requirements: [
            ProjectRequirement(
              id: board.requirements.first.id,
              title: 'Changed criterion',
              acceptance: board.requirements.first.acceptance,
              checks: board.requirements.first.checks,
            ),
            ...board.requirements.skip(1),
          ],
          tasks: board.tasks,
        ),
      );
      final changed = store.load(project);
      expect(
        changed.observationCurrent(changed.manualObservations.single),
        isFalse,
      );
      expect(
        jsonDecode(changed.evidenceJson)['manualObservations'].single['status'],
        'stale',
      );
      await expectLater(
        store.recordManualObservation(
          project,
          selected,
          selected.results.first.requirement.id,
          'Observe',
          false,
          DateTime.now(),
          authorized: () => true,
        ),
        throwsStateError,
      );
    },
  );

  test(
    'reject unknown and automated checks and preserve corrupt observations',
    () async {
      final records = await fixture();
      final store = RequirementCheckReportStore(records);
      for (final id in ['Auto', 'Unknown']) {
        final selected = store.load(project);
        await expectLater(
          store.recordManualObservation(
            project,
            selected,
            selected.results.first.requirement.id,
            id,
            true,
            DateTime.now(),
            authorized: () => true,
          ),
          throwsStateError,
        );
      }
      expect(
        records.data.containsKey(ManualCheckObservationStore.key('p')),
        isFalse,
      );
      records.data[ManualCheckObservationStore.key('p')] = '{corrupt';
      expect(() => store.load(project), throwsFormatException);
      expect(records.data[ManualCheckObservationStore.key('p')], '{corrupt');
    },
  );

  test('failed and concurrent writes preserve prior observation and respect disposal', () async {
    final records = await fixture();
    final store = RequirementCheckReportStore(records);
    await record(store, true);
    final before = records.data[ManualCheckObservationStore.key('p')];
    records.fail = true;
    final controller = RequirementCheckReportController(project, store)..load();
    await controller.recordManualObservation(
      controller.report!.results.first.requirement.id,
      'Observe',
      false,
    );
    expect(controller.error, isNotNull);
    expect(records.data[ManualCheckObservationStore.key('p')], before);
    records.fail = false;
    records.gate = Completer<void>();
    final saving = controller.recordManualObservation(
      controller.report!.results.first.requirement.id,
      'Observe',
      false,
    );
    expect(controller.saving, isTrue);
    await controller.recordManualObservation(
      controller.report!.results.first.requirement.id,
      'Observe',
      false,
    );
    controller.dispose();
    records.gate!.complete();
    await saving;
    expect(records.data[ManualCheckObservationStore.key('p')], before);
  });

  test('transaction rejects changed input during a delayed save', () async {
    final records = await fixture();
    final store = RequirementCheckReportStore(records);
    records.beforeCommit = () => records.data['studio.application.v1.p'] = '{}';
    await expectLater(record(store, true), throwsStateError);
    expect(
      records.data.containsKey(ManualCheckObservationStore.key('p')),
      isFalse,
    );
  });

  test('native database reopen retains manual evidence and isolates corrupt records', () async {
    final fixtureRecords = await fixture();
    final directory = await Directory.systemTemp.createTemp('asg_manual_');
    final path = '${directory.path}/records.db';
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var native = await databaseFactoryIo.openDatabase(path);
    try {
      var database = await StudioDatabase.migrate(native, preferences);
      for (final entry in fixtureRecords.data.entries) {
        await database.setString(entry.key, entry.value);
      }
      await record(RequirementCheckReportStore(database), true);
      await native.close();
      native = await databaseFactoryIo.openDatabase(path);
      database = await StudioDatabase.migrate(native, preferences);
      final report = RequirementCheckReportStore(database).load(project);
      expect(
        report.observationCurrent(report.manualObservations.single),
        isTrue,
      );
      await StoreRef<String, String>('records')
          .record(ManualCheckObservationStore.key('p'))
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
            .record(ManualCheckObservationStore.key('p'))
            .get(native),
        '{corrupt',
      );
    } finally {
      await native.close();
      await directory.delete(recursive: true);
    }
  });

  test('changed source, failed verification and withdrawal cannot retain current manual evidence', () async {
    for (final change in ['source', 'failed', 'approval']) {
      final records = await fixture();
      final store = RequirementCheckReportStore(records);
      await record(store, true);
      final selected = store.load(project);
      if (change == 'approval') {
        final json =
            jsonDecode(records.data['studio.planApproval.v1.p']!) as Map;
        json['approved'] = false;
        records.data['studio.planApproval.v1.p'] = jsonEncode(json);
      } else {
        final json = jsonDecode(records.data['studio.generation.v1.p']!) as Map;
        if (change == 'source') {
          (json['sources'] as Map)['lib/main.dart'] = 'c' * 64;
        } else {
          json['phase'] = 'failed';
        }
        records.data['studio.generation.v1.p'] = jsonEncode(json);
      }
      final report = store.load(project);
      expect(
        report.observationCurrent(report.manualObservations.single),
        isFalse,
        reason: change,
      );
      expect(
        jsonDecode(report.evidenceJson)['manualObservations'].single['status'],
        'stale',
        reason: change,
      );
      await expectLater(
        store.recordManualObservation(
          project,
          selected,
          selected.results.first.requirement.id,
          'Observe',
          false,
          DateTime.now(),
          authorized: () => true,
        ),
        throwsStateError,
      );
    }
  });

  testWidgets(
    'narrow report records an explicit human observation and shows it after reload',
    (tester) async {
      final records = await fixture();
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final controller = RequirementCheckReportController(
        project,
        RequirementCheckReportStore(records),
      );
      await tester.pumpWidget(
        MaterialApp(home: RequirementCheckReportScreen(controller: controller)),
      );
      final button = find.text('Record manual pass for Observe');
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(button), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(controller.report!.manualObservations.single.passed, isTrue);
      expect(find.text('Manual observation: passed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
