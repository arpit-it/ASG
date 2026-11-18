// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
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
  test('Stop intent is immutable and leaves journal, checkpoint and actual exits separate', () async {
    final records = AtomicRecords();
    final store = CandidateVerificationStore(records, 'p');
    final run = await store.start(
      failure().copy(steps: [], pendingOperation: 'resolve'),
      () {},
    );
    final before = Map<String, String>.of(records.values);
    final requestedAt = DateTime.now().toUtc();
    final request = await store.requestStop(requestedAt);
    expect(request!.matches('p', run), isTrue);
    for (final entry in before.entries) {
      expect(records.values[entry.key], entry.value);
    }
    expect(records.values.length, before.length + 1);
    expect(
      (await store.requestStop(requestedAt.add(const Duration(days: 1))))!
          .requestedAt,
      requestedAt,
    );
    await store.checkpoint(failure(exitCode: 65), () {}, finished: true);
    final finalRun = store.load().runs.single;
    expect(finalRun.snapshot.steps.last.exitCode, 65);
    expect(finalRun.snapshot.steps.last.cancelled, isFalse);
    expect(store.stopRequestFor(finalRun)!.requestedAt, requestedAt);
    expect(
      () => StudioDatabase.validate(
        'studio.candidateStop.v1.wrong:3',
        jsonEncode(request.toJson()),
      ),
      throwsFormatException,
    );
  });

  test('pending progress orders before Stop intent and failures do not poison the queue', () async {
    final records = AtomicRecords();
    final store = CandidateVerificationStore(records, 'p');
    await store.start(
      failure().copy(steps: [], pendingOperation: 'resolve'),
      () {},
    );
    final gate = Completer<void>();
    final entered = Completer<void>();
    records.beforeCommit = () async {
      records.beforeCommit = null;
      entered.complete();
      await gate.future;
    };
    final progress = store.checkpoint(
      failure(
        operation: 'resolve',
        exitCode: 0,
      ).copy(pendingOperation: 'analyze'),
      () {},
    );
    await entered.future;
    final stop = store.requestStop(DateTime.now().toUtc());
    await Future<void>.delayed(Duration.zero);
    expect(
      records.values.keys.where(
        (key) => key.startsWith(CandidateVerificationStore.stopPrefix),
      ),
      isEmpty,
    );
    gate.complete();
    await progress;
    await stop;
    expect(store.stopRequestFor(store.load().runs.single), isNotNull);
    final another = CandidateVerificationStore(records, 'other');
    await another.start(failure(), () {});
    final before = Map.of(records.values);
    records.failCommit = true;
    await expectLater(
      another.requestStop(DateTime.now().toUtc()),
      throwsStateError,
    );
    expect(records.values, before);
    records.failCommit = false;
    expect(await another.requestStop(DateTime.now().toUtc()), isNotNull);
  });

  test(
    'superseded sessions and changed inputs cannot attach Stop to another run',
    () async {
      final records = AtomicRecords();
      final old = CandidateVerificationStore(records, 'p');
      await old.start(failure().copy(steps: [], pendingOperation: ''), () {});
      final current = CandidateVerificationStore(records, 'p');
      await current.start(
        failure().copy(steps: [], pendingOperation: 'resolve'),
        () {},
      );
      final before = Map.of(records.values);
      await expectLater(
        old.requestStop(DateTime.now().toUtc()),
        throwsStateError,
      );
      expect(records.values, before);
      await current.checkpoint(failure().copy(sdk: '/changed'), () {});
      await expectLater(
        current.requestStop(DateTime.now().toUtc()),
        throwsStateError,
      );
      expect(
        records.values.keys.where(
          (key) => key.startsWith(CandidateVerificationStore.stopPrefix),
        ),
        isEmpty,
      );
    },
  );

  test(
    'reused store does not annotate a previous run when new startup fails',
    () async {
      final records = AtomicRecords();
      final store = CandidateVerificationStore(records, 'p');
      await store.start(failure(), () {});
      await store.checkpoint(failure(), () {}, finished: true);
      final before = Map.of(records.values);
      records.failCommit = true;
      await expectLater(store.start(failure(), () {}), throwsStateError);
      records.failCommit = false;
      expect(await store.requestStop(DateTime.now().toUtc()), isNull);
      expect(records.values, before);
    },
  );

  test('late Stop cannot attach to another or later execution state', () async {
    final records = AtomicRecords();
    final store = CandidateVerificationStore(records, 'p');
    final run = await store.start(failure(), () {});
    await store.checkpoint(failure(), () {}, finished: true);
    final key = 'studio.agentExecution.v1.${run.dispatchId!.split(':').first}';
    final original = jsonDecode(records.values[key]!) as Map<String, dynamic>;
    for (final changed in [
      {...original, 'taskId': 'other-task'},
      {...original, 'revision': 7},
    ]) {
      records.values[key] = jsonEncode(changed);
      final before = Map.of(records.values);
      await expectLater(
        store.requestStop(DateTime.now().toUtc()),
        throwsStateError,
      );
      expect(records.values, before);
    }
  });

  test('failed startup has no dispatch to annotate', () async {
    final records = AtomicRecords()..failCommit = true;
    final store = CandidateVerificationStore(records, 'p');
    final starting = expectLater(
      store.start(failure(), () {}),
      throwsStateError,
    );
    final stop = store.requestStop(DateTime.now().toUtc());
    await starting;
    expect(await stop, isNull);
    expect(records.values, isEmpty);
  });

  test(
    'Stop parser errors redact payloads without replacing evidence',
    () async {
      final records = AtomicRecords();
      final store = CandidateVerificationStore(records, 'p');
      final run = await store.start(failure(), () {});
      final key = '${CandidateVerificationStore.stopPrefix}${run.dispatchId}';
      records.values[key] = '{private malformed stop';
      try {
        store.stopRequestFor(run);
        fail('Malformed evidence accepted');
      } on FormatException catch (error) {
        expect(error.source, isNull);
      }
      expect(records.values[key], '{private malformed stop');
    },
  );

  test('native Stop intent reopens and corrupt evidence stays isolated and preserved', () async {
    SharedPreferences.setMockInitialValues({});
    final directory = await Directory.systemTemp.createTemp(
      'asg-stop-intent-db-',
    );
    final filename = '${directory.path}/records.db';
    var db = await databaseFactoryIo.openDatabase(filename);
    try {
      var records = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      final store = CandidateVerificationStore(records, 'p');
      final run = await store.start(
        failure().copy(steps: [], pendingOperation: 'resolve'),
        () {},
      );
      final request = await store.requestStop(DateTime.now().toUtc());
      final journal = records.getString(store.key);
      final stopKey =
          '${CandidateVerificationStore.stopPrefix}${run.dispatchId}';
      await db.close();
      db = await databaseFactoryIo.openDatabase(filename);
      records = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      final reopened = CandidateVerificationStore(records, 'p');
      expect(
        reopened.stopRequestFor(reopened.load().runs.single)!.toJson(),
        request!.toJson(),
      );
      expect(records.getString(store.key), journal);
      await expectLater(reopened.start(failure(), () {}), throwsStateError);
      await StoreRef<String, String>('records')
          .record(stopKey)
          .put(db, '{retained corrupt');
      await db.close();
      db = await databaseFactoryIo.openDatabase(filename);
      records = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      expect(
        () => CandidateVerificationStore(records, 'p').stopRequestFor(run),
        throwsFormatException,
      );
      expect(
        CandidateVerificationStore(records, 'p').load().runs.single.finished,
        isFalse,
      );
      expect(
        await StoreRef<String, String>('records').record(stopKey).get(db),
        '{retained corrupt',
      );
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });

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
