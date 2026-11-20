// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/imported_plan.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/services/imported_source_proposal_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'imported_plan_test.dart' as fixture;
import 'imported_source_proposal_controller_test.dart' as proposal;

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
            context: fixture.capturedSourcePlan().recordJson,
            approved: true,
            recordedAt: DateTime.utc(2026),
          ).toJson(),
        );
        await records.setString(key, original);
        final store = ImportedSourceProposalStore(records);
        final selected = store.read(
          fixture.finding(),
          fixture.capturedSourcePlan(),
        );
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
      final store = ImportedSourceProposalStore(r);
      final value = store.read(fixture.finding(), fixture.capturedSourcePlan());
      expect(() => value.inputs.clear(), throwsUnsupportedError);
      await expectLater(
        store.verify(value.inputs, () => throw StateError('closed')),
        throwsStateError,
      );
      expect(r.updatesSeen, isEmpty);
    },
  );
}
