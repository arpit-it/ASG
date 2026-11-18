// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'candidate_failure_test.dart' show failure;
import 'source_candidate_controller_test.dart' show AtomicRecords;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('atomic reservation/checkpoints retain exit evidence and refuse stale writers', () async {
    final records = AtomicRecords();
    final first = CandidateVerificationStore(records, 'p');
    final second = CandidateVerificationStore(records, 'p');
    final pending = failure().copy(steps: [], pendingOperation: '');
    await first.start(pending, () {});
    await second.start(pending, () {});
    final preserved = Map.of(records.values);
    await expectLater(
      first.checkpoint(failure(), () {}, finished: true),
      throwsStateError,
    );
    expect(records.values, preserved);
    await second.checkpoint(failure(), () {}, finished: true);
    final runs = second.load().runs;
    expect(runs.map((run) => run.number), [1, 2]);
    expect(runs.first.finished, isFalse);
    expect(runs.first.snapshot.pendingOperation, isEmpty);
    expect(runs.last.snapshot.steps.last.exitCode, 1);
    expect(runs.last.snapshot.steps.last.output, contains('line 2'));
    expect(runs.last.finished, isTrue);
  });

  test(
    'failed atomic writes and authorization leave both records unchanged',
    () async {
      final records = AtomicRecords();
      final store = CandidateVerificationStore(records, 'p');
      records.failCommit = true;
      await expectLater(store.start(failure(), () {}), throwsStateError);
      expect(records.values, isEmpty);
      records.failCommit = false;
      await expectLater(
        store.start(failure(), () => throw StateError('withdrawn')),
        throwsStateError,
      );
      expect(records.values, isEmpty);
      await store.start(failure(), () {});
      final before = Map.of(records.values);
      records.failCommit = true;
      await expectLater(
        store.checkpoint(failure(), () {}, finished: true),
        throwsStateError,
      );
      expect(records.values, before);
    },
  );

  test(
    'more than 32 runs retain evidence and malformed journals fail closed',
    () async {
      final records = AtomicRecords();
      final store = CandidateVerificationStore(records, 'p');
      for (var i = 0; i < 33; i++) {
        final writer = CandidateVerificationStore(records, 'p');
        await writer.start(failure(), () {});
        await writer.checkpoint(failure(), () {}, finished: true);
      }
      expect(store.load().runs.length, 33);
      await store.start(failure(), () {});
      expect(store.load().runs.length, 34);
      final before = records.values[store.key];
      final raw = jsonDecode(before!) as Map<String, dynamic>;
      for (final invalid in [
        {...raw, 'version': 1.0},
        {...raw, 'version': 2},
        {...raw, 'extra': true},
        {
          ...raw,
          'runs': [
            {...((raw['runs'] as List).first as Map), 'number': 2},
          ],
        },
      ]) {
        expect(
          () => CandidateVerificationJournal.fromJson(invalid),
          throwsFormatException,
        );
      }
    },
  );

  test(
    'missing linked execution refuses recovery and preserves unknown exit',
    () async {
      final records = AtomicRecords();
      final store = CandidateVerificationStore(records, 'p');
      await store.start(
        failure().copy(steps: [], pendingOperation: 'resolve'),
        () {},
      );
      final run = store.load().runs.single;
      final key =
          'studio.agentExecution.v1.${run.dispatchId!.split(':').first}';
      records.values.remove(key);
      final before = Map.of(records.values);
      var authorized = false;
      await expectLater(
        store.acknowledgeStopped(run, () {
          authorized = true;
        }),
        throwsStateError,
      );
      expect(authorized, isFalse);
      expect(records.values, before);
      expect(store.load().runs.single.finished, isFalse);
      expect(store.load().runs.single.snapshot.steps, isEmpty);
      await expectLater(
        CandidateVerificationStore(records, 'p').start(failure(), () {}),
        throwsStateError,
      );
      expect(records.values, before);
    },
  );

  test(
    'legacy unlinked interruption still requires explicit acknowledgement',
    () async {
      final records = AtomicRecords();
      final store = CandidateVerificationStore(records, 'p');
      await store.start(
        failure().copy(steps: [], pendingOperation: 'resolve'),
        () {},
      );
      final journal =
          jsonDecode(records.values[store.key]!) as Map<String, dynamic>;
      (journal['runs'] as List).single.remove('dispatchId');
      records.values[store.key] = jsonEncode(journal);
      final run = store.load().runs.single;
      expect(run.dispatchId, isNull);
      var authorized = false;
      await store.acknowledgeStopped(run, () {
        authorized = true;
      });
      expect(authorized, isTrue);
      final stopped = store.load().runs.single;
      expect(stopped.finished, isTrue);
      expect(stopped.snapshot.pendingOperation, 'resolve');
      expect(stopped.snapshot.steps, isEmpty);
    },
  );

  test('native close/reopen retains stopped and uncertain runs; corruption is isolated', () async {
    SharedPreferences.setMockInitialValues({});
    final folder = await Directory.systemTemp.createTemp('asg-check-journal-');
    try {
      final path = '${folder.path}/studio.db';
      var db = await databaseFactoryIo.openDatabase(path);
      var records = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      final store = CandidateVerificationStore(records, 'p');
      await store.start(failure(), () {});
      await store.checkpoint(failure(cancelled: true), () {}, finished: true);
      final interrupted = CandidateVerificationStore(records, 'p');
      await interrupted.start(
        failure().copy(steps: [], pendingOperation: 'resolve'),
        () {},
      );
      await interrupted.checkpoint(
        failure().copy(steps: [], pendingOperation: 'resolve'),
        () {},
      );
      final before = records.getString(store.key);
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      records = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      final reopened = CandidateVerificationStore(records, 'p');
      expect(records.getString(store.key), before);
      expect(reopened.load().runs.first.snapshot.steps.last.cancelled, isTrue);
      final first = reopened.load().runs.first;
      expect(first.dispatchId, 'candidate-p-1:3');
      final legacy = first.toJson()..remove('dispatchId');
      expect(CandidateVerificationRun.fromJson(legacy).dispatchId, isNull);
      final execution = jsonDecode(
        records.getString('studio.agentExecution.v1.candidate-p-1')!,
      ) as Map<String, dynamic>;
      expect(execution['phase'], 'verifying');
      expect(execution['revision'], 4);
      expect(reopened.load().runs.last.dispatchId, 'candidate-p-2:3');
      expect(reopened.load().runs.last.finished, isFalse);
      expect(reopened.load().runs.last.snapshot.pendingOperation, 'resolve');
      await expectLater(reopened.start(failure(), () {}), throwsStateError);
      expect(records.getString(store.key), before);
      final pendingRun = reopened.load().runs.last;
      await reopened.acknowledgeStopped(pendingRun, () {});
      expect(reopened.load().runs.last.finished, isTrue);
      expect(reopened.load().runs.last.snapshot.pendingOperation, 'resolve');
      expect(reopened.load().runs.last.snapshot.steps, isEmpty);
      await expectLater(
        reopened.acknowledgeStopped(pendingRun, () {}),
        throwsStateError,
      );
      await reopened.start(failure(), () {});
      expect(reopened.load().runs.length, 3);
      await StoreRef<String, String>('records')
          .record(store.key)
          .put(db, '{broken');
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      records = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      expect(() => records.getString(store.key), throwsFormatException);
      expect(CandidateVerificationStore(records, 'other').load().runs, isEmpty);
      expect(
        await StoreRef<String, String>('records').record(store.key).get(db),
        '{broken',
      );
      await db.close();
    } finally {
      await folder.delete(recursive: true);
    }
  });
}
