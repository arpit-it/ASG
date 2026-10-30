// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('browser')
library;

import 'dart:convert';

import 'package:asg/models/build_history_entry.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast_web/sembast_web.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Storage fixtures do not execute generated files or validate artifact existence.
GeneratedProject outcome(SourceGenerationPhase phase) => GeneratedProject(
  directory: '/synthetic/artifact',
  sdk: '/synthetic/sdk',
  python: 'python3',
  sources: {'lib/main.dart': 'a' * 64},
  phase: phase,
  steps: phase == SourceGenerationPhase.ready
      ? [
          for (final operation in ['resolve', 'analyze', 'test', 'build'])
            GenerationStep(operation: operation, exitCode: 0, output: 'ok'),
        ]
      : [],
  outputs: phase == SourceGenerationPhase.ready
      ? {'index.html': 'b' * 64, 'main.dart.js': 'c' * 64}
      : {},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final stale in [false, true]) {
    test('IndexedDB rollback records preserve work, stale=$stale', () async {
      final name = 'asg-history-${DateTime.now().microsecondsSinceEpoch}';
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var db = await databaseFactoryWeb.openDatabase(name);
      const key = 'studio.generation.v1.history';
      const backup = 'studio.generationPrevious.v1.history';
      try {
        var records = await StudioDatabase.migrate(db, prefs);
        var store = SourceGenerationStore(records);
        final success = outcome(SourceGenerationPhase.ready);
        final failure = outcome(SourceGenerationPhase.failed);
        await store.save('history', success);
        await store.save(
          'history',
          success,
        ); // repeated publication is idempotent
        await store.save('history', failure);
        await store.save('unrelated', success);
        final unrelated = records.getString('studio.generation.v1.unrelated');
        await db.close();
        db = await databaseFactoryWeb.openDatabase(name);
        records = await StudioDatabase.migrate(db, prefs);
        store = SourceGenerationStore(records);
        final history = store.history('history');
        expect(history.length, 2);
        expect(history.every((entry) => entry.recordedAt!.isUtc), isTrue);
        expect(history.first.project.toJson(), success.toJson());
        expect(history.last.project.toJson(), failure.toJson());
        final before = records.getString(key)!;
        // Neither a failed version nor a forged successful selection can restore.
        expect(
          () => store.encodeRollback('history', history.last),
          throwsStateError,
        );
        expect(
          () => store.encodeRollback(
            'history',
            BuildHistoryEntry(recordedAt: DateTime.utc(2000), project: success),
          ),
          throwsStateError,
        );
        final selected = store.encodeRollback('history', history.first);
        final updates = {key: selected, backup: before};
        if (stale) {
          // An independent session changes durable data while this cache is stale.
          final other = await StudioDatabase.migrate(db, prefs);
          await SourceGenerationStore(other)
              .save('history', failure.copy(error: 'newer saved work'));
          final changed = other.getString(key);
          await expectLater(
            records.commitRecords(
              expected: {key: before},
              updates: updates,
              authorize: () {},
            ),
            throwsStateError,
          );
          expect(records.getString(backup), isNull);
          await db.close();
          db = await databaseFactoryWeb.openDatabase(name);
          records = await StudioDatabase.migrate(db, prefs);
          expect(records.getString(key), changed);
          expect(records.getString(backup), isNull);
        } else {
          await expectLater(
            records.commitRecords(
              expected: {key: before},
              updates: updates,
              authorize: () => throw StateError('consent withdrawn'),
            ),
            throwsStateError,
          );
          expect(records.getString(key), before);
          expect(records.getString(backup), isNull);
          await records.commitRecords(
            expected: {key: before},
            updates: updates,
            authorize: () {},
          );
          await db.close();
          db = await databaseFactoryWeb.openDatabase(name);
          records = await StudioDatabase.migrate(db, prefs);
          store = SourceGenerationStore(records);
          expect(store.load('history')!.toJson(), success.toJson());
          expect(records.getString(backup), before);
          expect(
            jsonDecode(records.getString(key)!)['buildHistory'],
            jsonDecode(before)['buildHistory'],
          );
        }
        expect(records.getString('studio.generation.v1.unrelated'), unrelated);
        // Corruption remains readable as raw evidence; store writes refuse it.
        final raw = StoreRef<String, String>('records');
        const damaged = 'studio.generation.v1.damaged-history';
        final corrupt = jsonEncode({
          ...success.toJson(),
          'buildHistoryVersion': 1,
          'buildHistory': [
            {'recordedAt': 'invalid'},
          ],
        });
        await raw.record(damaged).put(db, corrupt);
        await db.close();
        db = await databaseFactoryWeb.openDatabase(name);
        records = await StudioDatabase.migrate(db, prefs);
        store = SourceGenerationStore(records);
        expect(() => store.load('damaged-history'), throwsFormatException);
        await expectLater(
          store.save('damaged-history', success),
          throwsFormatException,
        );
        expect(await raw.record(damaged).get(db), corrupt);
        expect(records.getString('studio.generation.v1.unrelated'), unrelated);
      } finally {
        await db.close();
        await databaseFactoryWeb.deleteDatabase(name);
      }
    });
  }
}
