import 'dart:convert';
import 'dart:io';

import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/repair_attempt.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/repair_attempt_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'approved_source_proposer_test.dart'
    show seed, serviceFor, originals, response;
import 'candidate_repair_proposer_test.dart' show boundFailure, saveFailure;
import 'planning_conversation_test.dart' show project, tick;
import 'source_candidate_controller_test.dart' show AtomicRecords;
import 'source_edit_proposer_test.dart' show FakeProvider;

import 'package:asg/models/local_model_config.dart';

CandidateVerificationRun run(AtomicRecords records) => CandidateVerificationRun(
  number: 1,
  startedAt: DateTime.utc(2026),
  snapshot: boundFailure(records),
  finished: true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('reserved interruptions and failures exhaust after three across service recreation', () async {
    final records = AtomicRecords();
    await seed(records);
    for (var i = 0; i < 3; i++) {
      final store = RepairAttemptStore(records, project.id);
      await store.reserve(run(records), () {});
      if (i == 1) await store.finish(RepairAttemptStatus.failed);
      if (i == 2) await store.finish(RepairAttemptStatus.cancelled);
    }
    final store = RepairAttemptStore(records, project.id);
    await expectLater(store.reserve(run(records), () {}), throwsStateError);
    expect(store.load().attempts.map((a) => a.status.name), [
      'reserved',
      'failed',
      'cancelled',
    ]);
    expect(store.load().attempts.last.failure.snapshot.steps.last.exitCode, 65);
  });

  test('categories have independent budgets and changed candidate paths do not reset them', () async {
    final records = AtomicRecords();
    await seed(records);
    final base = run(records);
    for (var i = 0; i < 3; i++) {
      await RepairAttemptStore(records, project.id).reserve(base, () {});
    }
    final moved = CandidateVerificationRun(
      number: 2,
      startedAt: DateTime.utc(2026),
      snapshot: GeneratedProject.fromJson({
        ...base.snapshot.toJson(),
        'directory': '/other/candidate',
      }),
      finished: true,
    );
    await expectLater(
      RepairAttemptStore(records, project.id).reserve(moved, () {}),
      throwsStateError,
    );
    final testFailure = CandidateVerificationRun(
      number: 2,
      startedAt: DateTime.utc(2026),
      snapshot: base.snapshot.copy(
        steps: [
          for (final task in base.snapshot.tasks!.takeWhile(
            (t) => t.operation.name != 'test',
          ))
            GenerationStep(
              operation: task.operation.name,
              exitCode: 0,
              output: 'passed',
            ),
          const GenerationStep(
            operation: 'test',
            exitCode: 1,
            output: 'expectation failed',
          ),
        ],
      ),
      finished: true,
    );
    await RepairAttemptStore(records, project.id).reserve(testFailure, () {});
    expect(
      RepairAttemptStore(
        records,
        project.id,
      ).load().attempts.map((a) => a.category),
      ['analyze', 'analyze', 'analyze', 'test'],
    );
  });

  test(
    'simultaneous reservations cannot overwrite or exceed the budget',
    () async {
      final records = AtomicRecords();
      await seed(records);
      final first = RepairAttemptStore(records, project.id);
      final second = RepairAttemptStore(records, project.id);
      var refused = 0;
      await Future.wait([
        first.reserve(run(records), () {}).catchError((Object _) {
          refused++;
        }),
        second.reserve(run(records), () {}).catchError((Object _) {
          refused++;
        }),
      ]);
      expect(refused, 1);
      expect(first.load().attempts.length, 1);
    },
  );

  test(
    'failed writes and withdrawn reservation never dispatch inference',
    () async {
      final records = AtomicRecords();
      await seed(records);
      final candidate = boundFailure(records);
      await saveFailure(records, candidate);
      records.failCommit = true;
      final provider = FakeProvider();
      await expectLater(
        serviceFor(records, provider).propose(
          project: project,
          boardTaskId: 'Tanalyze',
          config: const LocalModelConfig(),
          originals: originals,
          repairCandidate: candidate,
        ),
        throwsStateError,
      );
      expect(provider.prompt, isNull);
      expect(RepairAttemptStore(records, project.id).load().attempts, isEmpty);
      records.failCommit = false;
      final store = RepairAttemptStore(records, project.id);
      await expectLater(
        store.reserve(run(records), () => throw StateError('withdrawn')),
        throwsStateError,
      );
      expect(store.load().attempts, isEmpty);
    },
  );

  test('fourth real proposer request stops before transport; prior outcomes retained', () async {
    final records = AtomicRecords();
    await seed(records);
    final candidate = boundFailure(records);
    await saveFailure(records, candidate);
    for (var i = 0; i < 3; i++) {
      final provider = FakeProvider();
      final pending = serviceFor(records, provider).propose(
        project: project,
        boardTaskId: 'Tanalyze',
        config: const LocalModelConfig(),
        originals: originals,
        repairCandidate: candidate,
      );
      await tick();
      expect(provider.prompt, isNotNull);
      provider.stream.add(response());
      await provider.stream.close();
      await pending;
    }
    final provider = FakeProvider();
    await expectLater(
      serviceFor(records, provider).propose(
        project: project,
        boardTaskId: 'Tanalyze',
        config: const LocalModelConfig(),
        originals: originals,
        repairCandidate: candidate,
      ),
      throwsA(predicate((e) => '$e'.contains('budget exhausted'))),
    );
    expect(provider.prompt, isNull);
    expect(RepairAttemptStore(records, project.id).load().attempts.length, 3);
  });

  test('concurrent reservations retain both and finishing older attempt preserves newer', () async {
    final records = AtomicRecords();
    await seed(records);
    final first = RepairAttemptStore(records, project.id);
    final second = RepairAttemptStore(records, project.id);
    await first.reserve(run(records), () {});
    await second.reserve(run(records), () {});
    await first.finish(RepairAttemptStatus.failed);
    await second.finish(RepairAttemptStatus.cancelled);
    expect(first.load().attempts.map((a) => a.status.name), [
      'failed',
      'cancelled',
    ]);
    final third = RepairAttemptStore(records, project.id);
    await third.reserve(run(records), () {});
    final raw = records.values[third.key]!;
    final data = jsonDecode(raw) as Map<String, dynamic>;
    (data['attempts'] as List).removeLast();
    records.values[third.key] = jsonEncode(data);
    await expectLater(
      third.finish(RepairAttemptStatus.failed),
      throwsStateError,
    );
  });

  test(
    'unknown or missing attempt fields fail closed without replacing evidence',
    () async {
      final records = AtomicRecords();
      await seed(records);
      final store = RepairAttemptStore(records, project.id);
      await store.reserve(run(records), () {});
      final raw =
          jsonDecode(records.values[store.key]!) as Map<String, dynamic>;
      final attempt = (raw['attempts'] as List).single as Map<String, dynamic>;
      attempt.remove('proposal');
      attempt['unexpected'] = null;
      records.values[store.key] = jsonEncode(raw);
      final retained = records.values[store.key];
      expect(store.load, throwsFormatException);
      await expectLater(
        RepairAttemptStore(records, project.id).reserve(run(records), () {}),
        throwsFormatException,
      );
      expect(records.values[store.key], retained);
    },
  );

  test('native reopen retains budget; corrupt journal isolated without replacement', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final directory = await Directory.systemTemp.createTemp('repair-journal-');
    addTearDown(() => directory.delete(recursive: true));
    final path = '${directory.path}/studio.db';
    var db = await databaseFactoryIo.openDatabase(path);
    var records = await StudioDatabase.migrate(db, preferences);
    final fixtures = AtomicRecords();
    await seed(fixtures);
    final attempt = RepairAttemptStore(records, project.id);
    await attempt.reserve(run(fixtures), () {});
    await attempt.finish(RepairAttemptStatus.failed);
    await db.close();
    db = await databaseFactoryIo.openDatabase(path);
    records = await StudioDatabase.migrate(db, preferences);
    expect(
      RepairAttemptStore(records, project.id).load().attempts.single.status,
      RepairAttemptStatus.failed,
    );
    await db.close();
    db = await databaseFactoryIo.openDatabase(path);
    // Direct disk corruption must not be replaced or block unrelated records.
    await db.transaction((txn) async {
      await StoreRef<String, String>('records')
          .record(attempt.key)
          .put(txn, '{}');
    });
    records = await StudioDatabase.migrate(db, preferences);
    expect(
      () => RepairAttemptStore(records, project.id).load(),
      throwsFormatException,
    );
    expect(records.getString('unrelated'), isNull);
    await db.close();
  });
}
