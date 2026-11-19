// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_admission.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/agent_task_history_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approved_source_proposer_test.dart' show seed;
import 'planning_conversation_test.dart' show project;
import 'source_candidate_controller_test.dart' show AtomicRecords;
import 'agent_session_store_test.dart' show selection;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AtomicRecords records;
  late AgentSessionStore sessions;
  late AgentSessionRunAdmission admission;
  late GeneratedProject snapshot;
  late CandidateVerificationStore journal;
  late AgentTaskHistoryStore histories;
  setUp(() async {
    records = AtomicRecords();
    await seed(records);
    sessions = AgentSessionStore(records, project);
    final selected = await sessions.create('history', selection(records));
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
      sources: {'lib/main.dart': 'a' * 64},
      confined: true,
      approval: approval,
      tasks: BuildPlan.parse(
        approval.content,
        board: RequirementsStore(records).load(project.id),
      ).tasks,
      phase: SourceGenerationPhase.verifying,
      checkpointVersion: 1,
      pendingOperation: 'resolve',
    );
    journal = CandidateVerificationStore(records, project.id);
    histories = AgentTaskHistoryStore(records, project.id);
  });
  Future<CandidateVerificationRun> start() =>
      journal.start(snapshot, () {}, sessionAdmission: admission);
  GeneratedProject resolved() => snapshot.copy(
    pendingOperation: '',
    steps: [
      const GenerationStep(operation: 'resolve', exitCode: 0, output: 'actual'),
    ],
  );

  test('admission history joins the startup transaction and failed startup leaves no trace', () async {
    final before = Map.of(records.values);
    records.beforeCommit = () async {
      expect(records.getString(histories.keyFor(1)), isNull);
      expect(records.getString(journal.key), isNull);
    };
    records.failCommit = true;
    await expectLater(start(), throwsStateError);
    expect(records.values, before);
    records.failCommit = false;
    records.beforeCommit = null;
    final run = await start();
    final h = histories.load(run)!;
    expect(h.reference.dispatchId, run.dispatchId);
    expect(h.observations.map((item) => item.kind.name), [
      'admitted',
      'pending',
    ]);
    expect(h.version, 2);
    final saved = Map.of(records.values);
    expect(histories.load(run)!.toJson(), h.toJson());
    expect(records.values, saved);
  });

  test(
    'pending actual results and interrupted unknown remain jointly consistent',
    () async {
      await start();
      await journal.checkpoint(resolved(), () {});
      final pending = resolved().copy(pendingOperation: 'test');
      await journal.checkpoint(pending, () {});
      await journal.checkpoint(
        pending.copy(
          phase: SourceGenerationPhase.failed,
          failedOperation: 'test',
        ),
        () {},
      );
      final run = journal.load().runs.single;
      final h = histories.load(run)!;
      expect(h.results.single.exitCode, 0);
      expect(h.pendingOperation?.name, 'test');
      expect(h.observations.last.kind.name, 'interrupted');
      expect(h.observations.last.exitCode, isNull);
      expect(h.finished, isFalse);
      final before = Map.of(records.values);
      await expectLater(
        journal.checkpoint(run.snapshot, () {}, finished: true),
        throwsFormatException,
      );
      expect(records.values, before);
    },
  );

  test(
    'actual late result survives withdrawal without a new execution grant',
    () async {
      await start();
      await sessions.requestCancellation(journal.admittedSession!);
      await journal.checkpoint(
        resolved().copy(phase: SourceGenerationPhase.failed),
        () {},
        finished: true,
      );
      final run = journal.load().runs.single;
      final h = histories.load(run)!;
      expect(h.withdrawalSequence, 2);
      expect(h.results.single.exitCode, 0);
      expect(h.results.single.cancelled, isFalse);
      expect(h.finished, isTrue);
      expect(sessions.load('history')!.cancellationRequested, isTrue);
    },
  );

  test(
    'failed checkpoint preserves every byte and retry advances exactly once',
    () async {
      await start();
      final before = Map.of(records.values);
      records.failCommit = true;
      await expectLater(
        journal.checkpoint(resolved(), () {}),
        throwsStateError,
      );
      expect(records.values, before);
      records.failCommit = false;
      await journal.checkpoint(resolved(), () {});
      expect(histories.load(journal.load().runs.single)!.results.length, 1);
      await journal.checkpoint(resolved(), () {});
      expect(histories.load(journal.load().runs.single)!.results.length, 1);
    },
  );

  test(
    'superseded history or changed source refuses joint publication',
    () async {
      await start();
      final key = histories.keyFor(1);
      records.values[key] = '{retained corrupt history';
      final before = Map.of(records.values);
      await expectLater(
        journal.checkpoint(resolved(), () {}),
        throwsStateError,
      );
      expect(records.values, before);
      expect(
        () => histories.load(journal.load().runs.single),
        throwsFormatException,
      );
      expect(records.getString(key), before[key]);
      await expectLater(
        journal.checkpoint(
          GeneratedProject.fromJson({
            ...resolved().toJson(),
            'sources': {'lib/main.dart': 'b' * 64},
          }),
          () {},
        ),
        throwsFormatException,
      );
      expect(records.values, before);
    },
  );

  test(
    'withdrawal racing pending commit cannot leave a false dispatched intent',
    () async {
      await start();
      await journal.checkpoint(resolved(), () {});
      final beforeHistory = records.getString(histories.keyFor(1));
      records.beforeCommit = () async {
        records.beforeCommit = null;
        await sessions.requestCancellation(journal.admittedSession!);
      };
      await expectLater(
        journal.checkpoint(resolved().copy(pendingOperation: 'test'), () {}),
        throwsStateError,
      );
      expect(records.getString(histories.keyFor(1)), beforeHistory);
      expect(journal.load().runs.single.snapshot.pendingOperation, '');
      await journal.checkpoint(
        resolved().copy(phase: SourceGenerationPhase.failed),
        () {},
        finished: true,
      );
      final h = histories.load(journal.load().runs.single)!;
      expect(h.results.length, 1);
      expect(
        h.observations.where((item) => item.operation?.name == 'test'),
        isEmpty,
      );
    },
  );

  test('result without intent, combined result and dispatch, or changed prefix refuse', () async {
    await start();
    final before = Map.of(records.values);
    await expectLater(
      journal.checkpoint(resolved().copy(pendingOperation: 'test'), () {}),
      throwsFormatException,
    );
    await expectLater(
      journal.checkpoint(
        snapshot.copy(
          steps: [
            const GenerationStep(operation: 'analyze', exitCode: 0, output: ''),
          ],
          pendingOperation: '',
        ),
        () {},
      ),
      throwsFormatException,
    );
    expect(records.values, before);
    await journal.checkpoint(resolved(), () {});
    final retained = Map.of(records.values);
    await expectLater(
      journal.checkpoint(
        resolved().copy(
          steps: [
            const GenerationStep(
              operation: 'resolve',
              exitCode: 1,
              output: 'replaced',
            ),
          ],
        ),
        () {},
      ),
      throwsFormatException,
    );
    expect(records.values, retained);
  });

  test('database rejects foreign keys, oversized or malformed history without rewriting', () async {
    final run = await start();
    final raw = records.getString(histories.keyFor(1))!;
    StudioDatabase.validate(histories.keyFor(1), raw);
    expect(
      () => StudioDatabase.validate(histories.keyFor(2), raw),
      throwsFormatException,
    );
    expect(
      () => StudioDatabase.validate(histories.keyFor(1), 'x' * (300 * 1024)),
      throwsFormatException,
    );
    final changed = jsonDecode(raw) as Map<String, dynamic>;
    changed['command'] = 'ignored';
    expect(
      () => StudioDatabase.validate(histories.keyFor(1), jsonEncode(changed)),
      throwsFormatException,
    );
    final before = Map.of(records.values);
    expect(histories.load(run), isNotNull);
    expect(records.values, before);
  });

  test(
    'legacy unbound starts do not create histories or mutate on load',
    () async {
      final run = await journal.start(snapshot, () {});
      final before = Map.of(records.values);
      expect(histories.load(run), isNull);
      expect(records.getString(histories.keyFor(1)), isNull);
      expect(records.values, before);
    },
  );
  test(
    'acknowledgment retains unknown history and fresh consent uses another run',
    () async {
      await start();
      await journal.checkpoint(
        snapshot.copy(
          phase: SourceGenerationPhase.failed,
          failedOperation: 'resolve',
        ),
        () {},
      );
      final interrupted = journal.load().runs.single;
      final raw = records.getString(histories.keyFor(1));
      await journal.acknowledgeStopped(interrupted, () {});
      expect(records.getString(histories.keyFor(1)), raw);
      final acknowledged = journal.load().runs.single;
      expect(acknowledged.finished, isTrue);
      expect(histories.load(acknowledged)!.finished, isFalse);
      final nextJournal = CandidateVerificationStore(records, project.id);
      final current = sessions.load('history')!;
      final next = await nextJournal.start(
        snapshot,
        () {},
        sessionAdmission: AgentSessionRunAdmission(
          records,
          project,
          AgentSessionBinding.select(
            session: current,
            projectId: project.id,
            boardTaskId: 'Tresolve',
          ),
        ),
      );
      expect(next.number, 2);
      expect(histories.load(acknowledged)!.results, isEmpty);
      expect(records.getString(histories.keyFor(1)), raw);
      expect(histories.load(next)!.reference.runNumber, 2);
    },
  );

  for (final unknown in [true, false]) {
    test(
      'native reopen retains withdrawn ${unknown ? 'unknown' : 'late-result'} history without mutation',
      () async {
        final root = await Directory.systemTemp.createTemp('asg-task-history-');
        final dbPath = '${root.path}/records.db';
        SharedPreferences.setMockInitialValues({});
        final preferences = await SharedPreferences.getInstance();
        var db = await databaseFactoryIo.openDatabase(dbPath);
        try {
          var native = await StudioDatabase.migrate(db, preferences);
          for (final entry in records.values.entries) {
            await native.setString(entry.key, entry.value);
          }
          final current = AgentSessionStore(native, project).load('history')!;
          final store = CandidateVerificationStore(native, project.id);
          final run = await store.start(
            snapshot,
            () {},
            sessionAdmission: AgentSessionRunAdmission(
              native,
              project,
              AgentSessionBinding.select(
                session: current,
                projectId: project.id,
                boardTaskId: 'Tresolve',
              ),
            ),
          );
          await store.checkpoint(resolved(), () {});
          final pending = resolved().copy(pendingOperation: 'test');
          await store.checkpoint(pending, () {});
          await AgentSessionStore(
            native,
            project,
          ).requestCancellation(store.admittedSession!);
          final last = unknown
              ? pending.copy(
                  phase: SourceGenerationPhase.failed,
                  failedOperation: 'test',
                )
              : resolved().copy(
                  phase: SourceGenerationPhase.failed,
                  steps: [
                    ...resolved().steps,
                    const GenerationStep(
                      operation: 'test',
                      exitCode: 0,
                      output: 'fixture actual result',
                    ),
                  ],
                );
          await store.checkpoint(last, () {}, finished: !unknown);
          final keys = [
            store.key,
            store.candidateKey,
            current.storageKey,
            AgentTaskHistoryStore(native, project.id).keyFor(run.number),
            'studio.agentExecution.v1.candidate-${project.id}-${run.number}',
          ];
          final before = {for (final key in keys) key: native.getString(key)};
          await db.close();
          db = await databaseFactoryIo.openDatabase(dbPath);
          native = await StudioDatabase.migrate(db, preferences);
          final reopened = CandidateVerificationStore(
            native,
            project.id,
          ).load().runs.single;
          final h = AgentTaskHistoryStore(native, project.id).load(reopened)!;
          expect(h.results.length, unknown ? 1 : 2);
          expect(h.pendingOperation?.name, unknown ? 'test' : null);
          expect(h.finished, !unknown);
          expect(h.withdrawalSequence, isNotNull);
          if (unknown) {
            expect(h.observations.last.exitCode, isNull);
          }
          expect({for (final key in keys) key: native.getString(key)}, before);
        } finally {
          await db.close();
          await root.delete(recursive: true);
        }
      },
    );
  }
}
