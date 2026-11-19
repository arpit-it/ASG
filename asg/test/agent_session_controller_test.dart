// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/controllers/agent_session_controller.dart';
import 'package:asg/models/agent_session.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approved_source_proposer_test.dart' show seed;
import 'agent_session_store_test.dart' show savedRun;
import 'planning_conversation_test.dart' show project;
import 'source_candidate_controller_test.dart' show AtomicRecords;

void main() {
  late AtomicRecords records;
  late AgentSessionStore store;
  late AgentSessionController controller;
  var next = 0;
  setUp(() async {
    records = AtomicRecords();
    await seed(records);
    store = AgentSessionStore(records, project);
    next = 0;
    controller = AgentSessionController(
      store,
      createSessionId: () => 's${++next}',
    );
    controller.load();
  });
  tearDown(() {
    if (!controller.isDisposed) controller.dispose();
  });

  test('overview refreshes selected history without dispatch and clears on another session', () async {
    await controller.create(approved: true);
    final initial = controller.selected!;
    final run = await savedRun(records);
    await store.observeRun(initial, 'Tanalyze', run);
    final before = Map.of(records.values);
    controller.open(initial.sessionId);
    expect(controller.runStatuses.single.available, isTrue);
    expect(controller.runStatuses.single.pendingOperation, 'resolve');
    controller.load();
    expect(records.values, before);
    expect(() => controller.runStatuses.clear(), throwsUnsupportedError);
    await controller.create(approved: true);
    expect(controller.runStatuses, isEmpty);
    controller.open(initial.sessionId);
    records.values.remove('studio.agentExecution.v1.candidate-${project.id}-1');
    controller.load();
    expect(controller.runStatuses.single.available, isFalse);
    final count = controller.runStatuses.length;
    controller.dispose();
    controller.open(controller.selected!.sessionId);
    expect(controller.runStatuses.length, count);
  });

  test('review selection is explicit, read-only and rejects stale or cancelled context', () async {
    expect(controller.selectForSourceReview(), isNull);
    await controller.create(approved: true);
    final selected = controller.selected!;
    final before = Map.of(records.values);
    expect(controller.selectForSourceReview()!.toJson(), selected.toJson());
    expect(records.values, before);
    await store.requestCancellation(selected);
    expect(controller.selectForSourceReview(), isNull);
    controller.open(selected.sessionId);
    expect(controller.selectForSourceReview(), isNull);
    expect(controller.error, isNotNull);
  });

  test(
    'load/open are read-only and explicit create preserves prior records',
    () async {
      final before = Map.of(records.values);
      expect(controller.tasks, hasLength(4));
      expect(await controller.create(approved: false), isFalse);
      expect(records.values, before);
      expect(await controller.create(approved: true), isTrue);
      expect(controller.selected!.sessionId, 's1');
      expect(controller.sessions, hasLength(1));
      for (final entry in before.entries) {
        expect(records.values[entry.key], entry.value);
      }
      final saved = Map.of(records.values);
      controller.open('s1');
      controller.load();
      expect(records.values, saved);
      expect(() => controller.sessions.clear(), throwsUnsupportedError);
      expect(() => controller.selectedTaskIds.clear(), throwsUnsupportedError);
    },
  );

  test(
    'dependency selection stays closed and empty selection cannot create',
    () async {
      controller.toggleTask('Tresolve', false);
      expect(controller.selectedTaskIds, isEmpty);
      expect(controller.canCreate, isFalse);
      controller.toggleTask('Tbuild', true);
      expect(
        controller.selectedTaskIds,
        containsAll(['Tresolve', 'Tanalyze', 'Ttest', 'Tbuild']),
      );
      controller.toggleTask('unknown', true);
      expect(controller.selectedTaskIds, hasLength(4));
    },
  );

  test('save failure retains visible state and duplicate clicks do not publish twice', () async {
    final gate = Completer<void>();
    records.beforeCommit = () => gate.future;
    final pending = controller.create(approved: true);
    expect(controller.busy, isTrue);
    expect(controller.selected, isNull);
    expect(await controller.create(approved: true), isFalse);
    controller.toggleTask('Tresolve', false);
    expect(controller.selectedTaskIds, hasLength(4));
    records.failCommit = true;
    gate.complete();
    expect(await pending, isFalse);
    expect(controller.selected, isNull);
    expect(controller.sessions, isEmpty);
    expect(controller.error, contains('not saved'));
    expect(store.sessionIds(), isEmpty);
    records.beforeCommit = null;
    records.failCommit = false;
    expect(await controller.create(approved: true), isTrue);
    expect(controller.sessions.single.sessionId, 's2');
  });

  test(
    'late committed save after disposal cannot update or notify closed UI',
    () async {
      final gate = Completer<void>();
      records.beforeCommit = () => gate.future;
      var notifications = 0;
      controller.addListener(() => notifications++);
      final pending = controller.create(approved: true);
      final before = notifications;
      controller.dispose();
      gate.complete();
      expect(await pending, isFalse);
      expect(notifications, before);
      expect(controller.selected, isNull);
      expect(store.load('s1'), isNotNull);
    },
  );

  test('revoked approval blocks new sessions but permits retained cancellation intent', () async {
    await controller.create(approved: true);
    final value = controller.selected!;
    await PlanApprovalStore(records)
        .save(project, ConversationStore(records).load(project.id), false);
    controller.load();
    expect(controller.approvalError, isNotNull);
    expect(controller.canCreate, isFalse);
    expect(controller.sessions.single.sessionId, value.sessionId);
    final before = Map.of(records.values);
    expect(await controller.requestCancellation(), isTrue);
    expect(controller.selected!.cancellationRequested, isTrue);
    for (final entry in before.entries.where(
      (entry) => entry.key != value.storageKey,
    )) {
      expect(records.values[entry.key], entry.value);
    }
    expect(await controller.requestCancellation(), isFalse);
  });

  test(
    'corrupt list/records stay recoverable through explicit ID opening',
    () async {
      await controller.create(approved: true);
      final saved = controller.selected!;
      records.values['${AgentSessionCatalog.prefix}${project.id}'] =
          '{private-list';
      final before = Map.of(records.values);
      controller.load();
      expect(controller.historyError, isNotNull);
      expect(controller.canCreate, isFalse);
      controller.open(saved.sessionId);
      expect(controller.selected!.sessionId, saved.sessionId);
      expect(controller.canRemember, isFalse);
      controller.open('missing');
      expect(controller.error, isNotNull);
      expect(records.values, before);
      records.values.remove('${AgentSessionCatalog.prefix}${project.id}');
      controller.load();
      controller.open(saved.sessionId);
      expect(controller.canRemember, isTrue);
      expect(await controller.rememberSelected(), isTrue);
      expect(controller.sessions.single.sessionId, saved.sessionId);
      records.values[saved.storageKey] = '{private-record';
      controller.load();
      expect(controller.unavailableIds, [saved.sessionId]);
      expect('${controller.error}', isNot(contains('private-record')));
      expect(records.values[saved.storageKey], '{private-record');
    },
  );
  test(
    'missing selected record is explicit and last visible snapshot is retained',
    () async {
      await controller.create(approved: true);
      final selected = controller.selected!;
      records.values.remove(selected.storageKey);
      final before = Map.of(records.values);
      controller.load();
      expect(controller.unavailableIds, [selected.sessionId]);
      expect(controller.error, contains('last visible snapshot'));
      expect(controller.selected!.toJson(), selected.toJson());
      expect(records.values, before);
    },
  );

  test(
    'full catalog disables creation while existing sessions remain readable',
    () async {
      final ids = controller.selectedTaskIds.toList();
      for (var i = 0; i < AgentSessionCatalog.maxSessions; i++) {
        await store.create('capacity-$i', ids);
      }
      controller.load();
      expect(controller.sessionLimitReached, isTrue);
      expect(controller.canCreate, isFalse);
      final before = Map.of(records.values);
      expect(await controller.create(approved: true), isFalse);
      controller.open('capacity-0');
      expect(controller.selected!.sessionId, 'capacity-0');
      expect(records.values, before);
    },
  );
}
