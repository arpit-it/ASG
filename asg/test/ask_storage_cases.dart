// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/controllers/ask_controller.dart';
import 'package:asg/services/ask_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Answer implements ModelProvider {
  @override
  Stream<String> generate(String prompt) =>
      Stream.fromIterable(['Explanation Ω\n', '```dart\nfinal n = 1;\n```']);
  @override
  Future<void> cancel() async {}
}

Future<void> verifyAskStorage(DatabaseFactory factory, String name) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  var db = await factory.openDatabase(name);
  try {
    var records = await StudioDatabase.migrate(db, prefs);
    await records.setString('studio.projects.v1', '[]');
    await records.setString(
      'studio.chat.v1.unrelated',
      '[{"role":"user","content":"project private"}]',
    );
    final controller = AskController(
      AskStore(records),
      createProvider: (_) => _Answer(),
    )..load();
    expect(await controller.send('Explain a future Ω'), isTrue);
    controller.select(null);
    expect(await controller.send('Explain a stream'), isTrue);
    final expected = records.getString(AskStore.key);
    controller.dispose();
    for (var i = 0; i < 2; i++) {
      await db.close();
      db = await factory.openDatabase(name);
      records = await StudioDatabase.migrate(db, prefs);
      final reopened = AskController(
        AskStore(records),
        createProvider: (_) => _Answer(),
      )..load();
      expect(reopened.history.length, 2);
      expect(reopened.selectedId, 'ask-2');
      reopened.select('ask-1');
      expect(reopened.messages.first.content, 'Explain a future Ω');
      expect(reopened.messages.last.content, contains('final n = 1;'));
      expect(records.getString(AskStore.key), expected);
      expect(
        records.getString('studio.chat.v1.unrelated'),
        contains('project private'),
      );
      expect(records.getString('studio.projects.v1'), '[]');
      await expectLater(
        records.setString(AskStore.key, '{broken'),
        throwsFormatException,
      );
      expect(records.getString(AskStore.key), expected);
      final raw = StoreRef<String, String>('records');
      await expectLater(
        db.transaction((txn) async {
          await raw.record(AskStore.key).put(txn, '{broken');
          throw StateError('interrupted');
        }),
        throwsStateError,
      );
      expect(await raw.record(AskStore.key).get(db), expected);
      reopened.dispose();
    }
    // Corrupt Ask history is retained and isolated from the application database.
    final raw = StoreRef<String, String>('records');
    await raw.record(AskStore.key).put(db, '{broken');
    await db.close();
    db = await factory.openDatabase(name);
    records = await StudioDatabase.migrate(db, prefs);
    final damaged = AskController(AskStore(records))..load();
    expect(damaged.ready, isFalse);
    expect(await damaged.send('overwrite'), isFalse);
    expect(await raw.record(AskStore.key).get(db), '{broken');
    expect(records.getString('studio.projects.v1'), '[]');
    damaged.dispose();
  } finally {
    await db.close();
    await factory.deleteDatabase(name);
  }
}
