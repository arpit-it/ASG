// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/agent_execution_checkpoint.dart';
import 'package:asg/models/agent_session.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/agent_session_run_status_store.dart';
import 'package:asg/services/agent_task_history_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_session_store_test.dart' show savedRun, selection;
import 'approved_source_proposer_test.dart' show seed;
import 'planning_conversation_test.dart' show project;
import 'source_candidate_controller_test.dart' show AtomicRecords;

void main() {
  late AtomicRecords records;
  late AgentSession session;
  late AgentSessionRunStatusStore overview;
  setUp(() async {
    records = AtomicRecords();
    await seed(records);
    final store = AgentSessionStore(records, project);
    final initial = await store.create('status-session', selection(records));
    final run = await savedRun(records);
    session = await store.observeRun(initial, 'Tanalyze', run);
    overview = AgentSessionRunStatusStore(records, project.id);
  });

  test('read keeps pending execution unresolved and every byte unchanged', () {
    final before = Map.of(records.values);
    final status = overview.load(session).single;
    expect(status.available, isTrue);
    expect(status.executionPhase, AgentExecutionPhase.executing);
    expect(status.pendingOperation, 'resolve');
    expect(status.finished, isFalse);
    expect(records.values, before);
    expect(() => overview.load(session).clear(), throwsUnsupportedError);
  });

  test(
    'revoked approval and session cancellation do not erase saved facts',
    () async {
      session = await AgentSessionStore(
        records,
        project,
      ).requestCancellation(session);
      records.values.remove('studio.planApproval.v1.${project.id}');
      final before = Map.of(records.values);
      expect(overview.load(session).single.available, isTrue);
      expect(records.values, before);
    },
  );

  test(
    'missing corrupt and foreign checkpoint remain unavailable without writes',
    () {
      final key = 'studio.agentExecution.v1.candidate-${project.id}-1';
      for (final value in <String?>[
        null,
        '{private bad bytes',
        jsonEncode({
          'version': 1,
          'taskId': 'other-task',
          'revision': 3,
          'phase': 'executing',
        }),
        jsonEncode({
          'version': 1,
          'taskId': 'candidate-${project.id}-1',
          'revision': 9,
          'phase': 'executing',
        }),
      ]) {
        if (value == null) {
          records.values.remove(key);
        } else {
          records.values[key] = value;
        }
        final before = Map.of(records.values);
        final status = overview.load(session).single;
        expect(status.available, isFalse);
        expect(status.executionPhase, isNull);
        expect(records.values, before);
      }
    },
  );

  test(
    'ordered references isolate a missing checkpoint from valid history',
    () {
      final journalKey = 'studio.candidateChecks.v1.${project.id}';
      final journal =
          jsonDecode(records.values[journalKey]!) as Map<String, dynamic>;
      final first = (journal['runs'] as List).single as Map<String, dynamic>;
      final second = Map<String, dynamic>.from(first)
        ..['number'] = 2
        ..['dispatchId'] = 'candidate-${project.id}-2:3';
      journal['runs'] = [first, second];
      records.values[journalKey] = jsonEncode(journal);
      session = session.observe(
        AgentSessionDispatch(
          boardTaskId: 'Tanalyze',
          runNumber: 2,
          dispatchId: 'candidate-${project.id}-2:3',
        ),
      );
      records.values[session.storageKey] = jsonEncode(session.toJson());
      final before = Map.of(records.values);
      final statuses = overview.load(session);
      expect(statuses.map((status) => status.reference.runNumber), [1, 2]);
      expect(statuses.map((status) => status.available), [true, false]);
      expect(records.values, before);
    },
  );

  test('a different valid task graph cannot borrow the same approval', () {
    final key = 'studio.candidateChecks.v1.${project.id}';
    final journal = jsonDecode(records.values[key]!) as Map<String, dynamic>;
    final tasks = (journal['runs'] as List).single['snapshot']['tasks'] as List;
    final old = tasks.first['id'];
    tasks.first['id'] = 'renamed-resolve';
    for (final task in tasks) {
      task['dependencies'] = (task['dependencies'] as List)
          .map((id) => id == old ? 'renamed-resolve' : id)
          .toList();
    }
    records.values[key] = jsonEncode(journal);
    final before = Map.of(records.values);
    expect(overview.load(session).single.available, isFalse);
    expect(records.values, before);
  });

  test(
    'contradictory finished and checkpoint phases cannot look completed',
    () {
      final executionKey = 'studio.agentExecution.v1.candidate-${project.id}-1';
      records.values[executionKey] = jsonEncode({
        'version': 1,
        'taskId': 'candidate-${project.id}-1',
        'revision': 6,
        'phase': 'completed',
      });
      expect(overview.load(session).single.available, isFalse);
      final journalKey = 'studio.candidateChecks.v1.${project.id}';
      final journal =
          jsonDecode(records.values[journalKey]!) as Map<String, dynamic>;
      final run = (journal['runs'] as List).single;
      run['finished'] = true;
      run['snapshot']['phase'] = 'failed';
      records.values[journalKey] = jsonEncode(journal);
      expect(overview.load(session).single.available, isFalse);
      records.values[executionKey] = jsonEncode({
        'version': 1,
        'taskId': 'candidate-${project.id}-1',
        'revision': 3,
        'phase': 'executing',
      });
      expect(overview.load(session).single.available, isFalse);
      records.values[executionKey] = jsonEncode({
        'version': 1,
        'taskId': 'candidate-${project.id}-1',
        'revision': 4,
        'phase': 'verifying',
      });
      final before = Map.of(records.values);
      expect(overview.load(session).single.available, isTrue);
      expect(overview.load(session).single.pendingOperation, 'resolve');
      expect(records.values, before);
    },
  );

  test('stale session or wrong project refuses apparently matching run', () {
    final before = Map.of(records.values);
    expect(
      AgentSessionRunStatusStore(
        records,
        'foreign',
      ).load(session).single.available,
      isFalse,
    );
    records.values[session.storageKey] = jsonEncode(
      session.requestCancellation().toJson(),
    );
    expect(overview.load(session).single.available, isFalse);
    expect(records.values.length, before.length);
  });

  test(
    'missing corrupt approval or dispatch mismatch does not invent history',
    () {
      final key = 'studio.candidateChecks.v1.${project.id}';
      final raw = records.values[key]!;
      final alteredDispatch = jsonDecode(raw) as Map<String, dynamic>;
      (alteredDispatch['runs'] as List).single['dispatchId'] =
          'candidate-other-1:3';
      final alteredApproval = jsonDecode(raw) as Map<String, dynamic>;
      (alteredApproval['runs'] as List)
              .single['snapshot']['approval']['content'] =
          'different';
      for (final value in <String?>[
        null,
        'bad private journal',
        jsonEncode(alteredDispatch),
        jsonEncode(alteredApproval),
      ]) {
        if (value == null) {
          records.values.remove(key);
        } else {
          records.values[key] = value;
        }
        final before = Map.of(records.values);
        expect(overview.load(session).single.available, isFalse);
        expect(records.values, before);
      }
    },
  );
  test(
    'validated retained task observations are projected without record writes',
    () {
      final run = CandidateVerificationStore(
        records,
        project.id,
      ).load().runs.single;
      final history = AgentTaskHistoryStore.start(session, run);
      final histories = AgentTaskHistoryStore(records, project.id);
      records.values[histories.keyFor(run.number)] = jsonEncode(
        history.toJson(),
      );
      final before = Map.of(records.values);
      final status = overview.load(session).single;
      expect(status.available, isTrue);
      expect(status.taskHistory, isNotNull);
      expect(status.taskHistory!.observations.map((item) => item.kind.name), [
        'admitted',
        'pending',
      ]);
      expect(status.taskHistory!.pendingOperation?.name, 'resolve');
      expect(records.values, before);
    },
  );
  test(
    'missing corrupt and foreign task history retain independent run facts',
    () async {
      final run = CandidateVerificationStore(
        records,
        project.id,
      ).load().runs.single;
      final histories = AgentTaskHistoryStore(records, project.id);
      expect(overview.load(session).single.taskHistory, isNull);
      records.values[histories.keyFor(run.number)] = '{private-history-token';
      var before = Map.of(records.values);
      var status = overview.load(session).single;
      expect(status.available, isTrue);
      expect(status.pendingOperation, 'resolve');
      expect(status.taskHistory, isNull);
      expect(records.values, before);
      final sessions = AgentSessionStore(records, project);
      final other = await sessions.create(
        'foreign-history',
        selection(records),
      );
      final foreign = await sessions.observeRun(other, 'Tanalyze', run);
      records.values[histories.keyFor(run.number)] = jsonEncode(
        AgentTaskHistoryStore.start(foreign, run).toJson(),
      );
      before = Map.of(records.values);
      status = overview.load(session).single;
      expect(status.available, isTrue);
      expect(status.taskHistory, isNull);
      expect(records.values, before);
    },
  );

  test(
    'cancelled and revoked history stays readable without renewed approval',
    () async {
      final run = CandidateVerificationStore(
        records,
        project.id,
      ).load().runs.single;
      final history = AgentTaskHistoryStore.start(session, run);
      session = await AgentSessionStore(
        records,
        project,
      ).requestCancellation(session);
      final withdrawn = history.observeWithdrawal(currentSession: session);
      records.values[AgentTaskHistoryStore(
        records,
        project.id,
      ).keyFor(run.number)] = jsonEncode(
        withdrawn.toJson(),
      );
      records.values.remove('studio.planApproval.v1.${project.id}');
      final before = Map.of(records.values);
      final status = overview.load(session).single;
      expect(status.available, isTrue);
      expect(status.taskHistory!.withdrawalSequence, 2);
      expect(status.taskHistory!.results, isEmpty);
      expect(records.values, before);
    },
  );
}
