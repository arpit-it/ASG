// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/imported_commit_copy_controller.dart';
import 'package:asg/models/imported_commit_copy_request.dart';
import 'package:asg/services/imported_commit_copy_store.dart';
import 'package:asg/services/imported_commit_proposal_store.dart';
import 'package:asg/services/imported_source_proposal_store.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'imported_commit_copy_controller_test.dart' as fixture;
import 'imported_plan_test.dart' show finding;
import 'imported_source_proposal_record_test.dart' as working;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('six current inputs are frozen and changed full plan cannot borrow old proposal approval', () async {
    final r = await fixture.copyRecords(), store = ImportedCommitCopyStore(r);
    final selected = store.read(finding());
    expect(selected.inputs.length, 6);
    expect(() => selected.inputs.clear(), throwsUnsupportedError);
    final key = ImportedPlanStore.key('/project');
    final changed = jsonDecode(r.values[key]!) as Map<String, dynamic>;
    changed['text'] = 'A different approved plan';
    r.values[key] = jsonEncode(changed);
    expect(() => store.read(finding()), throwsStateError);
    expect(r.values[ImportedCommitCopyStore.key('/project')], isNull);
  });
  test('restored labels cannot substitute foreign immutable commit or selected metadata', () async {
    final r = await fixture.copyRecords();
    final selected = ImportedCommitCopyStore(r).read(finding());
    final targetStore = ImportedCommitCopyStore(r);
    final original = ImportedCommitCopyRequest.create(
      saved: selected.saved,
      python: selected.python,
      destination: '/copies',
      attemptId: 'a' * 32,
    );
    for (final change in <void Function(Map<String, dynamic>)>[
      (d) => d['commit'] = 'f' * 40,
      (d) => d['tree'] = 'e' * 40,
      (d) => d['manifest_sha256'] = 'f' * 64,
      (d) => d['manifest_files'] = 2,
      (d) => d['selected_files'][0]['git_blob'] = 'e' * 40,
      (d) => d['selected_files'][0]['mode'] = '100755',
    ]) {
      final data = jsonDecode(original.requestJson) as Map<String, dynamic>;
      change(data);
      final forged = ImportedCommitCopyRequest.restore(jsonEncode(data));
      await expectLater(
        targetStore.begin(selected, forged, DateTime.utc(2026), () {}),
        throwsStateError,
      );
    }
    expect(r.values[ImportedCommitCopyStore.key('/project')], isNull);
    expect(targetStore.read(finding()).history.attempts, isEmpty);
  });
  test(
    'caller mutation cannot rebase a pending durable verification',
    () async {
      final r = await fixture.copyRecords(), store = ImportedCommitCopyStore(r);
      final inputs = Map<String, String?>.of(store.read(finding()).inputs);
      r.gate = Completer();
      final pending = store.verify(inputs, () {});
      final key = ImportedPlanStore.key('/project');
      r.values[key] = r.values[key]!.replaceFirst(
        'Review literal replacement',
        'Changed reviewed plan',
      );
      inputs[key] = r.values[key];
      r.gate!.complete();
      await expectLater(pending, throwsStateError);
      expect(r.updatesSeen, everyElement(isEmpty));
    },
  );
  test(
    'recovery acknowledgement cannot replace a competing journal winner',
    () async {
      final r = await fixture.copyRecords(), store = ImportedCommitCopyStore(r);
      final selected = store.read(finding());
      final request = ImportedCommitCopyRequest.create(
        saved: selected.saved,
        python: selected.python,
        destination: '/copies',
        attemptId: 'a' * 32,
      );
      final pending = await store.begin(
        selected,
        request,
        DateTime.utc(2026),
        () {},
      );
      final old = store.history('/project');
      final winner = pending.history.acknowledge(DateTime.utc(2027));
      r.values[ImportedCommitCopyStore.key('/project')] = winner.recordJson;
      await expectLater(
        store.acknowledge(old, DateTime.utc(2026), () {}),
        throwsStateError,
      );
      expect(
        r.values[ImportedCommitCopyStore.key('/project')],
        winner.recordJson,
      );
    },
  );
  test('native pending admission survives restart without dispatch; acknowledgement and quarantine preserve old histories', () async {
    final root = await Directory.systemTemp.createTemp('asg-copy-history-db-');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    try {
      final records = await StudioDatabase.migrate(db, prefs),
          seed = await fixture.copyRecords();
      for (final entry in seed.values.entries) {
        await records.setString(entry.key, entry.value);
      }
      final oldWorking = working.historicalRecord().encode(),
          workingKey = ImportedSourceProposalStore.key('/project');
      await records.setString(workingKey, oldWorking);
      final proposalKey = ImportedCommitProposalStore.key('/project'),
          oldProposal = records.getString(
            ImportedCommitProposalStore.key('/project'),
          );
      final store = ImportedCommitCopyStore(records),
          selected = ImportedCommitCopyStore(records).read(finding());
      final request = ImportedCommitCopyRequest.create(
        saved: selected.saved,
        python: selected.python,
        destination: '/copies',
        attemptId: 'a' * 32,
      );
      await store.begin(selected, request, DateTime.utc(2026), () {});
      await db.close();
      db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      final reopened = await StudioDatabase.migrate(db, prefs);
      final host = fixture.CopyHost();
      final c = ImportedCommitCopyController(
        root: '/project',
        inspection: finding(),
        store: ImportedCommitCopyStore(reopened),
        host: host,
        clock: () => DateTime.utc(2026),
      );
      await c.load();
      expect(c.history!.needsRecovery, true);
      expect(c.canReview, false);
      expect(c.canPrepare, false);
      expect(host.calls, 0);
      await c.acknowledge(c.history!, inspectedAndStopped: false);
      expect(c.history!.needsRecovery, true);
      await c.acknowledge(c.history!, inspectedAndStopped: true);
      expect(c.history!.needsRecovery, false);
      expect(c.history!.lastPrepared, isNull);
      expect(host.calls, 0);
      expect(reopened.getString(workingKey), oldWorking);
      expect(reopened.getString(proposalKey), oldProposal);
      final target = ImportedCommitCopyStore.key('/project');
      expect(
        () => StudioDatabase.validate(
          ImportedCommitCopyStore.key('/other'),
          c.history!.recordJson,
        ),
        throwsFormatException,
      );
      await StoreRef<String, String>('records')
          .record(target)
          .put(db, 'private corrupt copy history');
      c.dispose();
      await db.close();
      db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      final quarantined = await StudioDatabase.migrate(db, prefs);
      expect(
        () => ImportedCommitCopyStore(quarantined).history('/project'),
        throwsStateError,
      );
      expect(
        await StoreRef<String, String>('records').record(target).get(db),
        'private corrupt copy history',
      );
      expect(quarantined.getString(workingKey), oldWorking);
      expect(quarantined.getString(proposalKey), oldProposal);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
  test(
    'native durable fence detects changed plan behind a stale session cache',
    () async {
      final root = await Directory.systemTemp.createTemp('asg-copy-fence-db-');
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = await databaseFactoryIo.openDatabase(
        '${root.path}/records.db',
      );
      try {
        final records = await StudioDatabase.migrate(db, prefs),
            seed = await fixture.copyRecords();
        for (final entry in seed.values.entries) {
          await records.setString(entry.key, entry.value);
        }
        final store = ImportedCommitCopyStore(records),
            selected = ImportedCommitCopyStore(records).read(finding());
        final key = ImportedPlanStore.key('/project'),
            original = records.getString(ImportedPlanStore.key('/project'))!;
        final changed = original.replaceFirst(
          'Review literal replacement',
          'External approved plan',
        );
        await StoreRef<String, String>('records').record(key).put(db, changed);
        expect(records.getString(key), original);
        await expectLater(
          store.verify(selected.inputs, () {}),
          throwsStateError,
        );
        expect(
          await StoreRef<String, String>('records').record(key).get(db),
          changed,
        );
        expect(
          records.getString(ImportedCommitCopyStore.key('/project')),
          isNull,
        );
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    },
  );
}
