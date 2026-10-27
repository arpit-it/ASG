// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/model_provider.dart';
import 'package:flutter_test/flutter_test.dart';

class FailingRecords implements RecordStorage {
  final values = <String, String>{};
  int writes = 0, failAt = 1;
  Completer<void>? gate;
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    await gate?.future;
    if (writes >= failAt) {
      throw StateError('PRIVATE_PROMPT token=secret /private/record');
    }
    values[key] = value;
    return true;
  }
}

class Reply implements ModelProvider {
  @override
  Stream<String> generate(String prompt) => Stream.value('completed response');
  @override
  Future<void> cancel() async {}
}

const project = StudioProject(
  id: 'privacy',
  name: 'Demo',
  description: '',
  type: 'Flutter',
  platforms: ['Web'],
  location: '',
);
void main() {
  for (final completed in [false, true]) {
    test(
      'save failures stay private and recover: completed=$completed',
      () async {
        final records = FailingRecords()..failAt = completed ? 2 : 1;
        final store = ConversationStore(records);
        var requests = 0;
        final c = ChatController(
          project,
          openStore: () async => store,
          createProvider: (_) {
            requests++;
            return Reply();
          },
        );
        await c.load();
        expect(await c.send('PRIVATE_PROMPT'), completed);
        expect(requests, completed ? 1 : 0);
        expect(c.messages, hasLength(completed ? 1 : 0));
        expect(c.hasUnsavedResponse, completed);
        void expectPrivate() {
          for (final marker in [
            'PRIVATE_PROMPT',
            'token=secret',
            '/private/',
          ]) {
            expect(c.error, isNot(contains(marker)));
            expect(c.requestDiagnostic, isNot(contains(marker)));
          }
          expect(c.requestDiagnostic, contains('failed'));
        }

        expectPrivate();
        if (completed) {
          await c.retrySavingResponse();
          expectPrivate();
          expect(c.hasUnsavedResponse, isTrue);
          records.failAt = 100;
          await c.retrySavingResponse();
        } else {
          records.failAt = 100;
          expect(await c.send('retry'), isTrue);
        }
        expect(c.error, isNull);
        expect(c.hasUnsavedResponse, isFalse);
        expect(c.messages, hasLength(2));
        expect(store.load(project.id), hasLength(2));
        expect(c.requestDiagnostic, contains('No chat request active'));
        c.dispose();
      },
    );
  }
  test('disposed pending save failure cannot publish diagnostics', () async {
    final records = FailingRecords()..gate = Completer<void>();
    final c = ChatController(
      project,
      openStore: () async => ConversationStore(records),
      createProvider: (_) => throw StateError('must not start'),
    );
    await c.load();
    final sending = c.send('PRIVATE_PROMPT');
    c.dispose();
    records.gate!.complete();
    expect(await sending, isFalse);
    expect(c.error, isNull);
    expect(c.messages, isEmpty);
  });
}
