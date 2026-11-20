// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:async';
import 'dart:io';

import 'package:asg/models/imported_plan.dart';
import 'package:asg/controllers/imported_commit_proposal_controller.dart';
import 'package:asg/models/imported_commit_proposal_record.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/services/imported_commit_proposal_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'imported_plan_test.dart' as fixture;
import 'imported_source_proposal_record_test.dart' as working;

import 'package:asg/services/imported_source_proposal_store.dart';

import 'imported_commit_proposal_record_test.dart' show capturedCommitPlan;
import 'imported_commit_proposal_controller_test.dart' as proposal;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'production read fence detects changed durable plan behind session cache',
    () async {
      final root = await Directory.systemTemp.createTemp('asg-proposal-fence-');
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      var db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      try {
        final records = await StudioDatabase.migrate(db, preferences);
        await InspectedFolderStore(records).save('/project');
        final key = ImportedPlanStore.key('/project');
        final original = jsonEncode(
          ImportedPlan(
            text: 'Reviewed',
            context: capturedCommitPlan().recordJson,
            approved: true,
            recordedAt: DateTime.utc(2026),
          ).toJson(),
        );
        await records.setString(key, original);
        final store = ImportedCommitProposalStore(records);
        final selected = store.read(fixture.finding(), capturedCommitPlan());
        await store.verify(selected.inputs, () {});
        final rows = StoreRef<String, String>('records');
        final changed = original.replaceFirst('Reviewed', 'Externally changed');
        await rows.record(key).put(db, changed);
        expect(records.getString(key), original);
        await expectLater(
          store.verify(selected.inputs, () {}),
          throwsStateError,
        );
        expect(await rows.record(key).get(db), changed);
        await db.close();
        db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
        final reopened = await StudioDatabase.migrate(db, preferences);
        expect(reopened.getString(key), changed);
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
  test(
    'read snapshot is immutable and closed review refuses before fence',
    () async {
      final r = await proposal.proposalRecords();
      final store = ImportedCommitProposalStore(r);
      final value = store.read(fixture.finding(), capturedCommitPlan());
      expect(() => value.inputs.clear(), throwsUnsupportedError);
      await expectLater(
        store.verify(value.inputs, () => throw StateError('closed')),
        throwsStateError,
      );
      expect(r.updatesSeen, isEmpty);
    },
  );
  test('registered history saves and survives database reopen without current plan; key mismatch refuses', () async {
    final root = await Directory.systemTemp.createTemp('asg-saved-proposal-');
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    try {
      final records = await StudioDatabase.migrate(db, preferences);
      final oldHistory = working.historicalRecord().encode();
      final oldKey = ImportedSourceProposalStore.key('/project');
      await records.setString(oldKey, oldHistory);
      final seed = await proposal.proposalRecords();
      for (final entry in seed.values.entries) {
        await records.setString(entry.key, entry.value);
      }
      final c = ImportedCommitProposalController(
        inspection: fixture.finding(),
        context: capturedCommitPlan(),
        store: ImportedCommitProposalStore(records),
      );
      await c.load();
      await c.preview('lib/main.dart', 'Saved native replacement');
      await c.save(c.proposal!);
      expect(c.error, isNull);
      final saved = c.saved!;
      final target = ImportedCommitProposalStore.key('/project');
      expect(records.getString(target), saved.encode());
      expect(
        () => StudioDatabase.validate(
          ImportedCommitProposalStore.key('/other'),
          saved.encode(),
        ),
        throwsFormatException,
      );
      await StoreRef<String, String>('records')
          .record(ImportedPlanStore.key('/project'))
          .delete(db);
      c.dispose();
      await db.close();
      db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      final reopened = await StudioDatabase.migrate(db, preferences);
      expect(reopened.getString(oldKey), oldHistory);
      expect(
        await StoreRef<String, String>('records').record(oldKey).get(db),
        oldHistory,
      );
      final history = ImportedCommitProposalController.history(
        root: '/project',
        store: ImportedCommitProposalStore(reopened),
      );
      await history.load();
      expect(history.saved!.encode(), saved.encode());
      expect(history.saved!.proposal.replacement, 'Saved native replacement');
      expect(history.canPreview, isFalse);
      expect(
        ImportedCommitProposalRecord.decode(reopened.getString(target)!).digest,
        saved.digest,
      );
      history.dispose();
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
  test('actual durable previous-record conflict and corrupt reopen preserve physical bytes', () async {
    final root = await Directory.systemTemp.createTemp(
      'asg-saved-proposal-cas-',
    );
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    try {
      final records = await StudioDatabase.migrate(db, preferences);
      final oldHistory = working.historicalRecord().encode();
      final oldKey = ImportedSourceProposalStore.key('/project');
      await records.setString(oldKey, oldHistory);
      final seed = await proposal.proposalRecords();
      for (final entry in seed.values.entries) {
        await records.setString(entry.key, entry.value);
      }
      final c = ImportedCommitProposalController(
        inspection: fixture.finding(),
        context: capturedCommitPlan(),
        store: ImportedCommitProposalStore(records),
      );
      await c.load();
      await c.preview('lib/main.dart', 'First');
      await c.save(c.proposal!);
      final target = ImportedCommitProposalStore.key('/project'),
          original = c.saved!.encode();
      final changed = jsonDecode(original) as Map<String, dynamic>;
      changed['recordedAt'] = DateTime.utc(2027).toIso8601String();
      final winner = jsonEncode(changed);
      final rows = StoreRef<String, String>('records');
      await c.preview('lib/main.dart', 'Second');
      await rows.record(target).put(db, winner);
      expect(records.getString(target), original);
      await c.save(c.proposal!);
      expect(await rows.record(target).get(db), winner);
      expect(c.saved!.encode(), original);
      await rows.record(target).put(db, 'private corrupt record');
      c.dispose();
      await db.close();
      db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      final reopened = await StudioDatabase.migrate(db, preferences);
      expect(reopened.getString(oldKey), oldHistory);
      expect(
        await StoreRef<String, String>('records').record(oldKey).get(db),
        oldHistory,
      );
      final history = ImportedCommitProposalController.history(
        root: '/project',
        store: ImportedCommitProposalStore(reopened),
      );
      await history.load();
      expect(history.saved, isNull);
      expect(history.historyError, isNotNull);
      expect(await rows.record(target).get(db), 'private corrupt record');
      expect(history.canSave, isFalse);
      history.dispose();
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
  test(
    'save freezes caller expected inputs before a pending transaction',
    () async {
      final r = await proposal.proposalRecords();
      final c = proposal.proposalController(r);
      await c.load();
      await c.preview('lib/main.dart', 'First');
      await c.save(c.proposal!);
      await c.preview('lib/main.dart', 'Second');
      final store = ImportedCommitProposalStore(r);
      final inputs = Map<String, String?>.of(
        store.read(fixture.finding(), capturedCommitPlan()).inputs,
      );
      final record = ImportedCommitProposalRecord.create(
        context: c.context!,
        plan: c.plan!,
        proposal: c.proposal!,
        recordedAt: DateTime.utc(2026),
      );
      final target = ImportedCommitProposalStore.key('/project');
      final changed = jsonDecode(c.saved!.encode()) as Map<String, dynamic>;
      changed['recordedAt'] = DateTime.utc(2027).toIso8601String();
      final winner = jsonEncode(changed);
      r.writeGate = Completer<void>();
      final pending = store.save(record, fixture.finding(), inputs, () {});
      r.values[target] = winner;
      inputs[target] = winner;
      r.writeGate!.complete();
      await expectLater(pending, throwsStateError);
      expect(r.values[target], winner);
      c.dispose();
    },
  );
}
