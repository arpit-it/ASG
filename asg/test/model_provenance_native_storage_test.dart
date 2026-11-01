// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('vm')
library;

import 'dart:io';

import 'package:asg/models/chat_message.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('native database reopens completed request metadata with legacy replies intact', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final dir = await Directory.systemTemp.createTemp(
      'asg-request-provenance-',
    );
    final path = '${dir.path}/records.db';
    var db = await databaseFactoryIo.openDatabase(path);
    try {
      final records = await StudioDatabase.migrate(db, prefs);
      await ConversationStore(records).save('project', [
        const ChatMessage(role: 'assistant', content: 'Legacy'),
        const ChatMessage(
          role: 'assistant',
          content: 'Completed',
          modelRequest: ModelRequestProvenance(
            model: 'requested-model',
            outputTokens: 1024,
          ),
        ),
      ]);
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      final reopened = await StudioDatabase.migrate(db, prefs);
      final saved = ConversationStore(reopened).load('project');
      expect(saved.first.modelRequest, isNull);
      expect(saved.last.modelRequest!.model, 'requested-model');
      expect(saved.last.modelRequest!.outputTokens, 1024);
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });
}
