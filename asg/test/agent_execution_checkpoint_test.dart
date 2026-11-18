// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/models/agent_execution_checkpoint.dart';
import 'package:asg/services/agent_execution_checkpoint_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('premature phases and repeated planning are corrupt evidence', () {
    final minimums = {
      AgentExecutionPhase.created: 0,
      AgentExecutionPhase.planning: 1,
      AgentExecutionPhase.awaitingApproval: 2,
      AgentExecutionPhase.executing: 3,
      AgentExecutionPhase.recovering: 4,
      AgentExecutionPhase.verifying: 4,
      AgentExecutionPhase.reviewing: 5,
      AgentExecutionPhase.completed: 6,
      AgentExecutionPhase.cancelled: 1,
    };
    for (final entry in minimums.entries) {
      for (var revision = 0; revision < entry.value; revision++) {
        expect(
          () => AgentExecutionCheckpoint.fromJson({
            'version': 1,
            'taskId': 'task',
            'revision': revision,
            'phase': entry.key.name,
          }),
          throwsFormatException,
          reason: '${entry.key.name} at $revision',
        );
      }
    }
    for (final phase in [
      AgentExecutionPhase.created,
      AgentExecutionPhase.planning,
    ]) {
      expect(
        () => AgentExecutionCheckpoint.fromJson({
          'version': 1,
          'taskId': 'task',
          'revision': 2,
          'phase': phase.name,
        }),
        throwsFormatException,
      );
    }
  });

  test('legal retry and recovery transition paths still round-trip', () {
    var frontier = [AgentExecutionCheckpoint.create('task')];
    final seen = <String>{};
    for (var depth = 0; depth <= 14; depth++) {
      final next = <AgentExecutionCheckpoint>[];
      for (final checkpoint in frontier) {
        expect(
          AgentExecutionCheckpoint.fromJson(checkpoint.toJson()).toJson(),
          checkpoint.toJson(),
        );
        if (checkpoint.requiresReconciliation) {
          expect(checkpoint.dispatchId, matches(r'^task:[1-9][0-9]*$'));
        }
        for (final phase in AgentExecutionPhase.values) {
          try {
            final advanced = checkpoint.advance(phase);
            if (seen.add('${advanced.revision}:${advanced.phase.name}')) {
              next.add(advanced);
            }
          } on StateError {
            // Invalid transitions are refused by the existing lifecycle.
          }
        }
      }
      frontier = next;
    }
    expect(seen, contains('6:completed'));
    expect(seen, contains('6:executing'));
    expect(seen, contains('7:recovering'));
  });

  test('native impossible phase remains preserved and cannot reopen', () async {
    SharedPreferences.setMockInitialValues({});
    final folder = await Directory.systemTemp.createTemp('asg-corrupt-phase-');
    var db = await databaseFactoryIo.openDatabase('${folder.path}/studio.db');
    try {
      final initialRecords = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      await AgentExecutionCheckpointStore(initialRecords).create('unrelated');
      final key = 'studio.agentExecution.v1.task';
      final rawStore = StoreRef<String, String>('records').record(key);
      for (final phase in ['recovering', 'completed']) {
        final raw = jsonEncode({
          'version': 1,
          'taskId': 'task',
          'revision': 1,
          'phase': phase,
        });
        await rawStore.put(db, raw);
        await db.close();
        db = await databaseFactoryIo.openDatabase('${folder.path}/studio.db');
        final records = await StudioDatabase.migrate(
          db,
          await SharedPreferences.getInstance(),
        );
        await expectLater(
          AgentExecutionCheckpointStore(records).reopen('task'),
          throwsFormatException,
        );
        expect(await rawStore.get(db), raw);
        expect(
          AgentExecutionCheckpointStore(records).load('unrelated')!.phase,
          AgentExecutionPhase.created,
        );
      }
    } finally {
      await db.close();
      await folder.delete(recursive: true);
    }
  });

  test(
    'interrupted dispatch survives restart and requires reconciliation',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final dir = await Directory.systemTemp.createTemp(
        'asg-agent-checkpoint-',
      );
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/studio.db';
      var db = await databaseFactoryIo.openDatabase(path);
      addTearDown(() => db.close());
      var store = AgentExecutionCheckpointStore(
        await StudioDatabase.migrate(db, prefs),
      );
      final created = await store.create('task-1');
      await expectLater(store.create('task-1'), throwsStateError);
      await expectLater(
        store.advance(created, AgentExecutionPhase.completed),
        throwsStateError,
      );
      final planning = await store.advance(
        created,
        AgentExecutionPhase.planning,
      );
      await expectLater(
        store.advance(created, AgentExecutionPhase.planning),
        throwsStateError,
      );
      final pending = await store.advance(
        planning,
        AgentExecutionPhase.awaitingApproval,
      );
      await expectLater(
        store.advance(pending, AgentExecutionPhase.executing),
        throwsStateError,
      );
      final dispatched = await store.advance(
        pending,
        AgentExecutionPhase.executing,
        authorize: () {},
      );
      await db.close();

      db = await databaseFactoryIo.openDatabase(path);
      store = AgentExecutionCheckpointStore(
        await StudioDatabase.migrate(db, prefs),
      );
      final recovering = (await store.reopen('task-1'))!;
      expect(recovering.phase, AgentExecutionPhase.recovering);
      expect(recovering.revision, dispatched.revision + 1);
      expect(dispatched.dispatchId, isNotNull);
      expect(recovering.dispatchId, dispatched.dispatchId);
      expect((await store.reopen('task-1'))!.revision, recovering.revision);
      await expectLater(
        store.advance(
          recovering,
          AgentExecutionPhase.executing,
          authorize: () {},
        ),
        throwsStateError,
      );
      await expectLater(
        store.advance(recovering, AgentExecutionPhase.awaitingApproval),
        throwsStateError,
      );
      await expectLater(
        store.advance(
          recovering,
          AgentExecutionPhase.awaitingApproval,
          reconciledDispatchId: recovering.dispatchId,
          authorize: () => throw StateError('Dispatch still unresolved'),
        ),
        throwsStateError,
      );
      for (final id in [null, 'different-task:3']) {
        await expectLater(
          store.advance(
            recovering,
            AgentExecutionPhase.awaitingApproval,
            reconciledDispatchId: id,
            authorize: () {},
          ),
          throwsStateError,
        );
      }
      expect(store.load('task-1')!.requiresReconciliation, isTrue);
      final reconciled = await store.advance(
        recovering,
        AgentExecutionPhase.awaitingApproval,
        reconciledDispatchId: recovering.dispatchId,
        authorize: () {},
      );
      expect(reconciled.requiresReconciliation, isFalse);
      await expectLater(
        store.advance(reconciled, AgentExecutionPhase.executing),
        throwsStateError,
      );
      var completed = await store.advance(
        reconciled,
        AgentExecutionPhase.executing,
        authorize: () {},
      );
      completed = await store.advance(completed, AgentExecutionPhase.verifying);
      completed = await store.advance(completed, AgentExecutionPhase.reviewing);
      completed = await store.advance(completed, AgentExecutionPhase.completed);
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      store = AgentExecutionCheckpointStore(
        await StudioDatabase.migrate(db, prefs),
      );
      final reopened = (await store.reopen('task-1'))!;
      expect(reopened.toJson(), completed.toJson());
      expect(reopened.requiresReconciliation, isFalse);
      await expectLater(
        store.advance(
          reopened,
          AgentExecutionPhase.executing,
          authorize: () {},
        ),
        throwsStateError,
      );
      expect(store.load('task-1')!.toJson(), completed.toJson());
    },
  );
}
