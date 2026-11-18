// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/models/agent_session.dart';
import 'package:asg/models/agent_execution_checkpoint.dart';
import 'package:asg/services/agent_execution_checkpoint_store.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'approved_source_proposer_test.dart' show seed;
import 'planning_conversation_test.dart' show project;
import 'source_candidate_controller_test.dart' show AtomicRecords;

List<String> selection(AtomicRecords records) =>
    RequirementsStore(records)
        .load(project.id)
        .tasks
        .map((task) => task.id)
        .toList();

Future<CandidateVerificationRun> savedRun(
  ConditionalRecordStorage records,
) async {
  final approval = PlanApprovalStore(records).requireCurrentApproval(project);
  return CandidateVerificationStore(records, project.id).start(
    GeneratedProject(
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
    ),
    () {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AtomicRecords records;
  late AgentSessionStore store;
  setUp(() async {
    records = AtomicRecords();
    await seed(records);
    store = AgentSessionStore(records, project);
  });

  test(
    'create/observe records only session data; reopen is a pure read',
    () async {
      final run = await savedRun(records);
      final before = Map.of(records.values);
      final initial = await store.create('s1', selection(records));
      final observed = await store.observeRun(initial, 'Tanalyze', run);
      for (final entry in before.entries) {
        expect(records.values[entry.key], entry.value);
      }
      expect(records.values.keys.toSet().difference(before.keys.toSet()), {
        observed.storageKey,
        '${AgentSessionCatalog.prefix}${project.id}',
      });
      final after = Map.of(records.values);
      expect(store.load('s1')!.toJson(), observed.toJson());
      expect(store.load('missing'), isNull);
      expect(records.values, after);
      expect(
        jsonDecode(
          records.values['studio.agentExecution.v1.candidate-${project.id}-1']!,
        )['phase'],
        'executing',
      );
    },
  );

  test(
    'duplicate/stale writes and failed commit preserve every record',
    () async {
      final initial = await store.create('s1', selection(records));
      final before = Map.of(records.values);
      await expectLater(
        store.create('s1', selection(records)),
        throwsStateError,
      );
      expect(records.values, before);
      records.failCommit = true;
      await expectLater(store.requestCancellation(initial), throwsStateError);
      expect(records.values, before);
      records.failCommit = false;
      final cancelled = await store.requestCancellation(initial);
      final after = Map.of(records.values);
      await expectLater(store.requestCancellation(initial), throwsStateError);
      expect(records.values, after);
      expect(store.load('s1')!.toJson(), cancelled.toJson());
    },
  );

  test(
    'revocation blocks observations but never prevents cancellation intent',
    () async {
      final run = await savedRun(records);
      final initial = await store.create('s1', selection(records));
      await PlanApprovalStore(records)
          .save(project, ConversationStore(records).load(project.id), false);
      final before = Map.of(records.values);
      await expectLater(
        store.observeRun(initial, 'Tanalyze', run),
        throwsStateError,
      );
      await expectLater(
        store.create('s2', selection(records)),
        throwsStateError,
      );
      expect(records.values, before);
      expect(
        (await store.requestCancellation(initial)).cancellationRequested,
        isTrue,
      );
      expect(
        records.values['studio.agentExecution.v1.candidate-${project.id}-1'],
        before['studio.agentExecution.v1.candidate-${project.id}-1'],
      );
    },
  );

  test(
    'approval withdrawal at commit and concurrent session writes fail closed',
    () async {
      records.beforeCommit = () async {
        records.beforeCommit = null;
        await PlanApprovalStore(records)
            .save(project, ConversationStore(records).load(project.id), false);
      };
      await expectLater(
        store.create('s1', selection(records)),
        throwsStateError,
      );
      expect(store.load('s1'), isNull);
      await seed(records);
      final initial = await store.create('s1', selection(records));
      final a = store.requestCancellation(initial),
          b = store.requestCancellation(initial);
      final results = await Future.wait([
        a.then((_) => true, onError: (_) => false),
        b.then((_) => true, onError: (_) => false),
      ]);
      expect(results.where((value) => value), hasLength(1));
    },
  );

  test('forged/unsaved dispatch, duplicate reference and wrong member refuse mutation', () async {
    final run = await savedRun(records);
    final initial = await store.create('s1', selection(records));
    final before = Map.of(records.values);
    final forged = CandidateVerificationRun.fromJson({
      ...run.toJson(),
      'dispatchId': 'candidate-other-1:3',
    });
    await expectLater(
      store.observeRun(initial, 'Tanalyze', forged),
      throwsStateError,
    );
    await expectLater(
      store.observeRun(initial, 'unknown', run),
      throwsStateError,
    );
    expect(records.values, before);
    final next = await store.observeRun(initial, 'Tanalyze', run);
    final after = Map.of(records.values);
    await expectLater(
      store.observeRun(next, 'Tanalyze', run),
      throwsFormatException,
    );
    expect(records.values, after);
  });

  test(
    'checkpoint change at observation commit cannot attach stale evidence',
    () async {
      final run = await savedRun(records);
      final initial = await store.create('s1', selection(records));
      final before = records.getString(initial.storageKey);
      final executions = AgentExecutionCheckpointStore(records);
      final active = executions.load('candidate-${project.id}-1')!;
      records.beforeCommit = () async {
        records.beforeCommit = null;
        await executions.advance(active, AgentExecutionPhase.verifying);
      };
      await expectLater(
        store.observeRun(initial, 'Tanalyze', run),
        throwsStateError,
      );
      expect(records.getString(initial.storageKey), before);
      expect(
        executions.load(active.taskId)!.phase,
        AgentExecutionPhase.verifying,
      );
    },
  );

  test(
    'corrupt reads redact private bytes and do not replace evidence',
    () async {
      final initial = await store.create('s1', selection(records));
      records.values[initial.storageKey] = '{private-plan-token';
      final before = Map.of(records.values);
      try {
        store.load('s1');
        fail('Expected corruption');
      } on FormatException catch (error) {
        expect('$error', isNot(contains('private-plan-token')));
        expect(error.source, isNull);
      }
      await expectLater(
        store.requestCancellation(initial),
        throwsFormatException,
      );
      expect(records.values, before);
    },
  );

  test('native reopen preserves observations, isolates corrupt sessions and never advances dispatch', () async {
    final root = await Directory.systemTemp.createTemp('asg-session-store-');
    final path = '${root.path}/records.db';
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase(path);
    try {
      var native = await StudioDatabase.migrate(db, preferences);
      for (final entry in records.values.entries) {
        await native.setString(entry.key, entry.value);
      }
      var sessions = AgentSessionStore(native, project);
      final run = await savedRun(native);
      final initial = await sessions.create('s1', selection(records));
      final observed = await sessions.observeRun(initial, 'Tanalyze', run);
      final executionKey = 'studio.agentExecution.v1.candidate-${project.id}-1';
      final originalExecution = native.getString(executionKey);
      final raw = native.getString(observed.storageKey);
      expect(sessions.sessionIds(), ['s1']);
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      native = await StudioDatabase.migrate(db, preferences);
      sessions = AgentSessionStore(native, project);
      expect(sessions.load('s1')!.toJson(), observed.toJson());
      expect(native.getString(observed.storageKey), raw);
      expect(sessions.sessionIds(), ['s1']);
      expect(native.getString(executionKey), originalExecution);
      final cancelled = await sessions.requestCancellation(observed);
      final recordsStore = StoreRef<String, String>('records');
      final corruptKey = '${AgentSession.prefix}${project.id}.corrupt';
      await recordsStore.record(corruptKey).put(db, '{private-plan');
      await expectLater(
        native.setString('${AgentSession.prefix}${project.id}.wrong', raw!),
        throwsFormatException,
      );
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      native = await StudioDatabase.migrate(db, preferences);
      sessions = AgentSessionStore(native, project);
      expect(() => sessions.load('corrupt'), throwsFormatException);
      expect(sessions.load('s1')!.toJson(), cancelled.toJson());
      expect(sessions.load('s1')!.cancellationRequested, isTrue);
      expect(await recordsStore.record(corruptKey).get(db), '{private-plan');
      final catalogKey = '${AgentSessionCatalog.prefix}${project.id}';
      await recordsStore.record(catalogKey).put(db, '{private-catalog');
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      native = await StudioDatabase.migrate(db, preferences);
      sessions = AgentSessionStore(native, project);
      expect(() => sessions.sessionIds(), throwsFormatException);
      expect(sessions.load('s1')!.toJson(), cancelled.toJson());
      expect(await recordsStore.record(catalogKey).get(db), '{private-catalog');

      expect(native.getString(executionKey), originalExecution);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
  test('catalog and session create atomically under failure or concurrent creation', () async {
    final before = Map.of(records.values);
    records.failCommit = true;
    await expectLater(store.create('s1', selection(records)), throwsStateError);
    expect(records.values, before);
    records.failCommit = false;
    final a = store.create('s1', selection(records)),
        b = store.create('s2', selection(records));
    final results = await Future.wait([
      a.then((value) => value.sessionId, onError: (_) => ''),
      b.then((value) => value.sessionId, onError: (_) => ''),
    ]);
    final winner = results.singleWhere((value) => value.isNotEmpty);
    expect(store.sessionIds(), [winner]);
    expect(store.load(winner), isNotNull);
    expect(store.load(winner == 's1' ? 's2' : 's1'), isNull);
  });

  test(
    'pre-index record can be explicitly remembered after approval withdrawal',
    () async {
      final value = await store.create('s1', selection(records));
      records.values.remove('${AgentSessionCatalog.prefix}${project.id}');
      await PlanApprovalStore(records)
          .save(project, ConversationStore(records).load(project.id), false);
      expect(store.sessionIds(), isEmpty);
      expect(store.load('s1')!.toJson(), value.toJson());
      final before = records.getString(value.storageKey);
      expect((await store.remember('s1')).toJson(), value.toJson());
      expect(store.sessionIds(), ['s1']);
      expect(records.getString(value.storageKey), before);
      final all = Map.of(records.values);
      await store.remember('s1');
      expect(records.values, all);
    },
  );

  test('corrupt catalog refuses discovery and new writes without hiding direct records', () async {
    final value = await store.create('s1', selection(records));
    final key = '${AgentSessionCatalog.prefix}${project.id}';
    records.values[key] = '{private-catalog';
    final before = Map.of(records.values);
    expect(() => store.sessionIds(), throwsFormatException);
    expect(store.load('s1')!.toJson(), value.toJson());
    await expectLater(
      store.create('s2', selection(records)),
      throwsFormatException,
    );
    expect(records.values, before);
  });
}
