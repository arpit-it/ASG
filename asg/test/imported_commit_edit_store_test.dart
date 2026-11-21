// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/models/imported_commit_copy_recheck.dart';
import 'package:asg/models/imported_commit_edit_request.dart';
import 'package:asg/models/imported_commit_edit_record.dart';
import 'package:asg/services/imported_commit_edit_store.dart';
import 'package:asg/services/imported_commit_copy_store.dart';
import 'package:asg/services/imported_commit_proposal_store.dart';
import 'package:asg/services/studio_database.dart';

import 'imported_commit_edit_controller_test.dart' show editRecords;
import 'imported_commit_copy_recheck_test.dart' show recheckResult;
import 'imported_plan_test.dart' show finding;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('seven durable current inputs and full rebuilt request reject restored foreign labels', () async {
    final r = await editRecords(),
        s = ImportedCommitEditStore(await editRecords());
    final store = ImportedCommitEditStore(r), selected = store.read(finding());
    expect(selected.inputs.length, 7);
    final read = ImportedCommitCopyRecheckRequest.create(
          history: selected.copyHistory,
          python: selected.python,
          recheckId: 'b' * 32,
        ),
        observed = recheckResult(
          ImportedCommitCopyRecheckRequest.create(
            history: selected.copyHistory,
            python: selected.python,
            recheckId: 'b' * 32,
          ),
        );
    final request = ImportedCommitEditRequest.create(
      copyHistory: selected.copyHistory,
      proposal: selected.saved,
      reviewed: read,
      observation: observed,
      python: selected.python,
      destination: '/output',
      attemptId: 'c' * 32,
    );
    final raw = jsonDecode(request.requestJson) as Map;
    for (final edit in [
      {'before_sha256': 'f' * 64},
      {'before_git_blob': 'f' * 40},
      {'before_mode': '100755'},
      {'expected_source_fingerprint': 'a' * 64},
      {'copy_history_sha256': 'a' * 64},
      {'proposal_history_sha256': 'a' * 64},
    ]) {
      final changed = ImportedCommitEditRequest.restore(
        jsonEncode({...raw, ...edit}),
      );
      await expectLater(
        store.begin(
          selected,
          changed,
          read,
          observed,
          DateTime.utc(2026),
          () {},
        ),
        throwsStateError,
      );
    }
    expect(r.values[ImportedCommitEditStore.key('/project')], isNull);
    expect(r.updatesSeen, isEmpty);
    final token = store.acquire();
    expect(store.readBusy, true);
    expect(s.readBusy, false);
    store.release(token);
  });
  test('pending native admission survives reopen and corrupt new history is isolated without rewriting old histories', () async {
    final temp = await Directory.systemTemp.createTemp('asg-edit-store-');
    var db = await databaseFactoryIo.openDatabase('${temp.path}/app.db');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    try {
      final source = await editRecords();
      var records = await StudioDatabase.migrate(db, prefs);
      for (final entry in source.values.entries) {
        await records.setString(entry.key, entry.value);
      }
      final original = records.getString(
            ImportedCommitCopyStore.key('/project'),
          ),
          proposal = records.getString(
            ImportedCommitProposalStore.key('/project'),
          );
      var store = ImportedCommitEditStore(records);
      final selected = store.read(finding());
      final read = ImportedCommitCopyRecheckRequest.create(
            history: selected.copyHistory,
            python: selected.python,
            recheckId: 'b' * 32,
          ),
          observed = recheckResult(
            ImportedCommitCopyRecheckRequest.create(
              history: selected.copyHistory,
              python: selected.python,
              recheckId: 'b' * 32,
            ),
          );
      final request = ImportedCommitEditRequest.create(
        copyHistory: selected.copyHistory,
        proposal: selected.saved,
        reviewed: read,
        observation: observed,
        python: selected.python,
        destination: '/output',
        attemptId: 'c' * 32,
      );
      await store.begin(
        selected,
        request,
        read,
        observed,
        DateTime.utc(2026),
        () {},
      );
      await db.close();
      db = await databaseFactoryIo.openDatabase('${temp.path}/app.db');
      records = await StudioDatabase.migrate(db, prefs);
      store = ImportedCommitEditStore(records);
      expect(
        store.history('/project').record.latest!.phase,
        ImportedCommitEditPhase.pending,
      );
      expect(store.history('/project').record.needsRecovery, true);
      await store.acknowledge(
        store.history('/project'),
        DateTime.utc(2026),
        () {},
      );
      expect(store.history('/project').record.lastPrepared, isNull);
      const raw = 'private corrupt proposed journal';
      await StoreRef<String, String>('records')
          .record(ImportedCommitEditStore.key('/project'))
          .put(db, raw);
      await db.close();
      db = await databaseFactoryIo.openDatabase('${temp.path}/app.db');
      records = await StudioDatabase.migrate(db, prefs);
      expect(
        () => records.getString(ImportedCommitEditStore.key('/project')),
        throwsFormatException,
      );
      expect(
        records.getString(ImportedCommitCopyStore.key('/project')),
        original,
      );
      expect(
        records.getString(ImportedCommitProposalStore.key('/project')),
        proposal,
      );
      expect(
        await StoreRef<String, String>('records')
            .record(ImportedCommitEditStore.key('/project'))
            .get(db),
        raw,
      );
    } finally {
      await db.close();
      await temp.delete(recursive: true);
    }
  });
}
