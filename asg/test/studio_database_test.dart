// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import 'package:asg/models/session_proposal_request.dart';
import 'package:asg/services/session_proposal_request_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'session_proposal_request_test.dart' show requestMetadata;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'database validates bounded canonical journal and exact storage identity',
    () {
      const key = '${SessionProposalRequestStore.prefix}project.session';
      final raw = SessionProposalRequestJournal([requestMetadata()]).encode();
      StudioDatabase.validate(key, raw);
      for (final entry in {
        key: '$raw ',
        '${SessionProposalRequestStore.prefix}project.other': raw,
        '${SessionProposalRequestStore.prefix}project.session.extra': raw,
        '${SessionProposalRequestStore.prefix}../session': raw,
      }.entries) {
        expect(
          () => StudioDatabase.validate(entry.key, entry.value),
          throwsFormatException,
        );
      }
    },
  );
  test('native reopen isolates corrupt request history while preserving its bytes and other records', () async {
    final root = await Directory.systemTemp.createTemp(
      'asg-request-corruption-',
    );
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    const key = '${SessionProposalRequestStore.prefix}project.session';
    const raw = '{"version":1,"requests":"corrupt"}';
    try {
      final initial = await StudioDatabase.migrate(db, preferences);
      await initial.setString('studio.lastProject.v1', 'unrelated-project');
      final persisted = StoreRef<String, String>('records');
      await persisted.record(key).put(db, raw);
      await db.close();
      db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      final reopened = await StudioDatabase.migrate(db, preferences);
      expect(reopened.getString('studio.lastProject.v1'), 'unrelated-project');
      expect(
        () =>
            SessionProposalRequestStore(reopened, 'project', 'session').load(),
        throwsFormatException,
      );
      expect(await persisted.record(key).get(db), raw);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
