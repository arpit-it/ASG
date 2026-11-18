// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import 'package:asg/models/agent_execution_checkpoint.dart';
import 'package:asg/services/agent_execution_checkpoint_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
