// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/services/agent_execution_checkpoint_store.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/agent_task_history_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approved_source_proposer_test.dart' show seed;
import 'planning_conversation_test.dart' show project;
import 'source_candidate_controller_test.dart' show AtomicRecords;

import 'dart:io';

import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/services/agent_session_admission.dart';

import 'agent_session_store_test.dart' show selection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AtomicRecords records;
  late AgentSessionStore sessions;
  late AgentSessionRunAdmission admission;
  late GeneratedProject snapshot;
  test('native reopen retains joint admission without replay', () async {
    final root = await Directory.systemTemp.createTemp('asg-bound-session-');
    final path = '${root.path}/records.db';
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase(path);
    try {
      var native = await StudioDatabase.migrate(db, preferences);
      for (final entry in records.values.entries) {
        await native.setString(entry.key, entry.value);
      }
      final initial = AgentSessionStore(native, project).load('bound')!;
      final journal = CandidateVerificationStore(native, project.id);
      final run = await journal.start(
        snapshot,
        () {},
        sessionAdmission: AgentSessionRunAdmission(
          native,
          project,
          AgentSessionBinding.select(
            session: initial,
            projectId: project.id,
            boardTaskId: 'Tresolve',
          ),
        ),
      );
      final admitted = native.getString(initial.storageKey);
      final historyKey = AgentTaskHistoryStore(
        native,
        project.id,
      ).keyFor(run.number);
      final history = native.getString(historyKey);
      final candidate = native.getString(journal.candidateKey);
      final executionKey = 'studio.agentExecution.v1.candidate-${project.id}-1';
      final execution = native.getString(executionKey);
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      native = await StudioDatabase.migrate(db, preferences);
      expect(native.getString(initial.storageKey), admitted);
      expect(native.getString(journal.candidateKey), candidate);
      expect(native.getString(executionKey), execution);
      expect(native.getString(historyKey), history);
      expect(
        AgentTaskHistoryStore(
          native,
          project.id,
        ).load(run)!.pendingOperation?.name,
        'resolve',
      );
      expect(
        native.getString(
          'studio.agentTaskHistory.v1.${project.id}.${run.number}',
        ),
        isNotNull,
        reason:
            'Bound admission must retain task history across native reopen.',
      );
      expect(
        CandidateVerificationStore(
          native,
          project.id,
        ).load().runs.single.toJson(),
        run.toJson(),
      );
      expect(
        AgentSessionStore(native, project).load('bound')!.dispatches,
        hasLength(1),
      );
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });

  setUp(() async {
    records = AtomicRecords();
    await seed(records);
    sessions = AgentSessionStore(records, project);
    final selected = await sessions.create('bound', selection(records));
    admission = AgentSessionRunAdmission(
      records,
      project,
      AgentSessionBinding.select(
        session: selected,
        projectId: project.id,
        boardTaskId: 'Tresolve',
      ),
    );
    final approval = PlanApprovalStore(records).requireCurrentApproval(project);
    snapshot = GeneratedProject(
      directory: '/candidate',
      sdk: '/sdk',
      python: 'python3',
      confined: true,
      sources: {'lib/main.dart': 'a' * 64},
      approval: approval,
      tasks: BuildPlan.parse(
        approval.content,
        board: RequirementsStore(records).load(project.id),
      ).tasks,
      phase: SourceGenerationPhase.verifying,
      checkpointVersion: 1,
      pendingOperation: 'resolve',
    );
  });

  test(
    'startup atomically appends session, journal, candidate and execution',
    () async {
      final store = CandidateVerificationStore(records, project.id);
      final run = await store.start(
        snapshot,
        () {},
        sessionAdmission: admission,
      );
      final saved = sessions.load('bound')!;
      expect(saved.dispatches.single.dispatchId, run.dispatchId);
      expect(saved.dispatches.single.boardTaskId, 'Tresolve');
      expect(store.admittedSession!.toJson(), saved.toJson());
      expect(store.load().runs.single.toJson(), run.toJson());
      expect(
        AgentExecutionCheckpointStore(records)
            .load('candidate-${project.id}-1')!
            .dispatchId,
        run.dispatchId,
      );
      expect(records.getString(store.candidateKey), isNotNull);
    },
  );

  test('failed transaction leaves all startup records unchanged', () async {
    final before = Map.of(records.values);
    records.failCommit = true;
    final store = CandidateVerificationStore(records, project.id);
    await expectLater(
      store.start(snapshot, () {}, sessionAdmission: admission),
      throwsStateError,
    );
    expect(records.values, before);
    expect(store.admittedSession, isNull);
  });

  test('cancellation during admission preserves cancellation but no startup records', () async {
    records.beforeCommit = () async {
      records.beforeCommit = null;
      await sessions.requestCancellation(admission.binding.session);
    };
    final store = CandidateVerificationStore(records, project.id);
    await expectLater(
      store.start(snapshot, () {}, sessionAdmission: admission),
      throwsStateError,
    );
    expect(sessions.load('bound')!.cancellationRequested, isTrue);
    expect(sessions.load('bound')!.dispatches, isEmpty);
    expect(store.load().runs, isEmpty);
    expect(records.getString(store.candidateKey), isNull);
    expect(
      AgentExecutionCheckpointStore(records).load('candidate-${project.id}-1'),
      isNull,
    );
  });

  test(
    'authorization refusal and foreign store cannot append a session',
    () async {
      final before = Map.of(records.values);
      await expectLater(
        CandidateVerificationStore(records, project.id).start(
          snapshot,
          () => throw StateError('disposed'),
          sessionAdmission: admission,
        ),
        throwsStateError,
      );
      await expectLater(
        CandidateVerificationStore(
          records,
          'other',
        ).start(snapshot, () {}, sessionAdmission: admission),
        throwsStateError,
      );
      expect(records.values, before);
    },
  );
}
