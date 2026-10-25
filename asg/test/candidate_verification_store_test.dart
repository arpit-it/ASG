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
    final pending = failure().copy(steps: [], pendingOperation: 'resolve');
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
    expect(runs.first.snapshot.pendingOperation, 'resolve');
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
      expect(reopened.load().runs.last.finished, isFalse);
      expect(reopened.load().runs.last.snapshot.pendingOperation, 'resolve');
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
