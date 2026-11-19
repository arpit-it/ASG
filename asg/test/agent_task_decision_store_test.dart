// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/candidate_reopen_context.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/controllers/source_candidate_controller.dart';
import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/agent_task_decision_store.dart';
import 'package:asg/services/named_check_observation_store.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'planning_conversation_test.dart' show project;
import 'published_task_evidence_store_test.dart'
    show evidenceFixture, EvidenceFixture;
import 'named_check_observation_test.dart' as named;
import 'candidate_reopen_context_test.dart' show reopenAfter, reopenHash;
import 'saved_candidate_recovery_controller_test.dart'
    show ReopenInspectionHost;

Future<EvidenceFixture> dependentPublication(
  EvidenceFixture first, {
  String taskId = 'Tanalyze',
  String beforeText = reopenAfter,
  String directory = '/dependent-candidate',
}) async {
  final records = first.records;
  final afterText = '$beforeText\n// dependent reviewed candidate';
  final evidence = ApprovedSourceProposal(
    projectId: project.id,
    boardTaskId: taskId,
    approval: first.session.approval,
    modelRequest: first.run.snapshot.sourceRequest,
    proposal: SourceEditProposal.parse(
      {
        'summary': 'Dependent reviewed candidate',
        'changes': [
          {'path': 'lib/main.dart', 'before': beforeText, 'after': afterText},
        ],
      },
      originals: {'lib/main.dart': beforeText},
      responseModel: first.run.snapshot.sourceRequest?.responseModel,
    ),
  );
  final prepared = GeneratedProject.fromJson({
    ...first.run.snapshot.toJson(),
    'directory': directory,
    'phase': SourceGenerationPhase.generated.name,
    'sources': {
      ...first.run.snapshot.sources,
      'lib/main.dart': reopenHash(afterText),
    },
    'steps': <Object>[],
    'outputs': <String, String>{},
    'pendingOperation': '',
    'failedOperation': '',
    'error': '',
  });
  final basis = CandidateReopenBasis.capture(
    projectId: project.id,
    workingRecord: records.getString('studio.generation.v1.${project.id}')!,
    working: first.run.snapshot,
    sourceBase: first.run.snapshot,
    prepared: prepared,
    evidence: evidence,
  );
  final owner = SourceGenerationController(
    project: project,
    definition: ApplicationStore(records).load(project).definition,
    store: SourceGenerationStore(records),
    host: ReopenInspectionHost(),
    selectedSession: first.session,
  );
  final candidate = SourceCandidateController(
    project: project,
    candidate: prepared,
    evidence: evidence,
    records: records,
    host: ReopenInspectionHost(),
    reopenBasis: basis,
    sessionBinding: AgentSessionBinding.select(
      session: first.session,
      projectId: project.id,
      boardTaskId: taskId,
    ),
    publish: (value, host, authorize) => owner.promoteCandidate(
      value,
      host,
      authorize,
      expectedWorking: first.run.snapshot,
    ),
  );
  await candidate.verify(approved: true);
  expect(candidate.error, isNull);
  expect(await candidate.promote(approved: true), isTrue);
  final result = (
    records: records,
    session: candidate.sessionBinding!.session,
    run: candidate.history.last,
  );
  candidate.dispose();
  owner.dispose();
  final reports = RequirementCheckReportStore(records);
  await reports.recordNamedTestResult(
    project,
    reports.load(project),
    'R1',
    'Auto',
    named.result(true),
    DateTime.utc(2026, 4),
    authorized: () => true,
  );
  return result;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'conflicting expected-absent decision is preserved instead of overwritten',
    () async {
      final f = await evidenceFixture(
        allAuthoredRules: true,
        taskId: 'Tresolve',
      );
      final store = AgentTaskDecisionStore(f.records, project);
      final first = store.select(f.session, f.run.number);
      final reports = RequirementCheckReportStore(f.records);
      await reports.recordNamedTestResult(
        project,
        reports.load(project),
        'R1',
        'Auto',
        named.result(true),
        DateTime.utc(2026, 5),
        authorized: () => true,
      );
      final replacement = store.select(f.session, f.run.number);
      final retained = await store.confirm(
        replacement,
        consent: true,
        authorized: () => true,
      );
      final before = Map.of(f.records.values);
      await expectLater(
        store.confirm(first, consent: true, authorized: () => true),
        throwsStateError,
      );
      expect(f.records.values, before);
      expect(
        store.load(f.session, f.run.number)!.fingerprint,
        retained.fingerprint,
      );
    },
  );

  test('explicit prior decision supports a newer dependent contract without rewriting history', () async {
    final first = await evidenceFixture(
      allAuthoredRules: true,
      taskId: 'Tresolve',
    );
    final store = AgentTaskDecisionStore(first.records, project);
    final prior = await store.confirm(
      store.select(first.session, first.run.number),
      consent: true,
      authorized: () => true,
    );
    final priorRaw = first.records.getString(prior.storageKey);
    final next = await dependentPublication(first);
    expect(() => store.select(next.session, next.run.number), throwsStateError);
    expect(
      () => store.select(
        next.session,
        next.run.number,
        prerequisites: {'Tresolve': next.run.number},
      ),
      throwsA(anything),
    );
    final selected = store.select(
      next.session,
      next.run.number,
      prerequisites: {'Tresolve': first.run.number},
    );
    final before = Map.of(first.records.values);
    final dependent = await store.confirm(
      selected,
      consent: true,
      authorized: () => true,
    );
    expect(first.records.values.length, before.length + 1);
    expect(first.records.getString(prior.storageKey), priorRaw);
    expect(dependent.evidence.prerequisites.single.sha256, prior.fingerprint);
    expect(
      store.load(next.session, first.run.number)!.fingerprint,
      prior.fingerprint,
    );
    expect(
      store.load(next.session, next.run.number)!.fingerprint,
      dependent.fingerprint,
    );
    first.records.values.remove(prior.storageKey);
    expect(
      () => store.load(next.session, next.run.number),
      throwsFormatException,
    );
  });

  test('selection writes nothing; explicit confirmation publishes only one immutable decision', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final store = AgentTaskDecisionStore(
      f.records,
      project,
      now: () => DateTime.utc(2026, 11, 19),
    );
    final before = Map.of(f.records.values);
    final selection = store.select(f.session, f.run.number);
    expect(f.records.values, before);
    final value = await store.confirm(
      selection,
      consent: true,
      authorized: () => true,
    );
    expect(f.records.values.length, before.length + 1);
    for (final e in before.entries) {
      expect(f.records.values[e.key], e.value);
    }
    final encoded = f.records.getString(value.storageKey);
    expect(encoded, jsonEncode(value.toJson()));
    expect(store.load(f.session, f.run.number)!.fingerprint, value.fingerprint);
    expect(
      (await store.confirm(
        selection,
        consent: true,
        authorized: () => true,
      )).fingerprint,
      value.fingerprint,
    );
    expect(f.records.getString(value.storageKey), encoded);
    expect(() => store.select(f.session, f.run.number), throwsStateError);
  });

  test('mixed rules and missing explicit prerequisite decisions refuse without writes', () async {
    for (final allRules in [false, true]) {
      final f = await evidenceFixture(
        allAuthoredRules: allRules,
        taskId: allRules ? 'Tanalyze' : 'Tresolve',
      );
      final before = Map.of(f.records.values);
      expect(
        () => AgentTaskDecisionStore(
          f.records,
          project,
        ).select(f.session, f.run.number),
        throwsA(anything),
      );
      expect(f.records.values, before);
    }
  });

  test('denied consent, authorization and a foreign store selection publish nothing', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final store = AgentTaskDecisionStore(f.records, project);
    final selected = store.select(f.session, f.run.number),
        before = Map.of(f.records.values);
    await expectLater(
      store.confirm(selected, consent: false, authorized: () => true),
      throwsStateError,
    );
    await expectLater(
      store.confirm(selected, consent: true, authorized: () => false),
      throwsStateError,
    );
    await expectLater(
      AgentTaskDecisionStore(
        f.records,
        project,
      ).confirm(selected, consent: true, authorized: () => true),
      throwsStateError,
    );
    expect(f.records.values, before);
  });

  test('replaced observations invalidate the displayed selection but not a retained historical decision', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final store = AgentTaskDecisionStore(f.records, project);
    final selected = store.select(f.session, f.run.number);
    final report = RequirementCheckReportStore(f.records);
    await report.recordNamedTestResult(
      project,
      report.load(project),
      'R1',
      'Auto',
      named.result(false),
      DateTime.utc(2026, 2),
      authorized: () => true,
    );
    final before = Map.of(f.records.values);
    await expectLater(
      store.confirm(selected, consent: true, authorized: () => true),
      throwsStateError,
    );
    expect(f.records.values, before);
    expect(() => store.select(f.session, f.run.number), throwsFormatException);
    await report.recordNamedTestResult(
      project,
      report.load(project),
      'R1',
      'Auto',
      named.result(true),
      DateTime.utc(2026, 3),
      authorized: () => true,
    );
    final decision = await store.confirm(
      store.select(f.session, f.run.number),
      consent: true,
      authorized: () => true,
    );
    final raw = f.records.getString(decision.storageKey);
    f.records.values[NamedCheckObservationStore.key(project.id)] =
        '{unreadable latest observation';
    f.records.values['studio.generation.v1.${project.id}'] = '{rotated working';
    final withdrawn = await AgentSessionStore(
      f.records,
      project,
    ).requestCancellation(f.session);
    expect(
      store.load(withdrawn, f.run.number)!.fingerprint,
      decision.fingerprint,
    );
    expect(f.records.getString(decision.storageKey), raw);
    expect(() => store.select(withdrawn, f.run.number), throwsStateError);
  });

  test('each changed read-set record at commit refuses, preserving that external change and all other records', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final baseline = Map.of(f.records.values);
    final keys = [
      f.session.storageKey,
      'studio.candidateChecks.v1.${project.id}',
      'studio.agentExecution.v1.${f.run.dispatchId!.split(':').first}',
      'studio.agentSessionPublication.v1.${project.id}.${f.run.number}',
      'studio.generation.v1.${project.id}',
      'studio.projects.v1',
      'studio.requirements.v1.${project.id}',
      'studio.application.v1.${project.id}',
      'studio.chat.v1.${project.id}',
      'studio.planApproval.v1.${project.id}',
      'studio.namedChecks.v1.${project.id}',
      'studio.manualChecks.v1.${project.id}',
    ];
    for (final key in keys) {
      f.records.values
        ..clear()
        ..addAll(baseline);
      f.records.beforeCommit = null;
      final store = AgentTaskDecisionStore(f.records, project);
      final selected = store.select(f.session, f.run.number);
      f.records.beforeCommit = () async {
        f.records.values[key] = '${baseline[key]} ';
      };
      await expectLater(
        store.confirm(selected, consent: true, authorized: () => true),
        throwsStateError,
        reason: key,
      );
      final expected = Map.of(baseline)..[key] = '${baseline[key]} ';
      expect(f.records.values, expected, reason: key);
    }
  });

  test('authorization withdrawn while commit waits and failed storage publish no decision', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final store = AgentTaskDecisionStore(f.records, project);
    final selected = store.select(f.session, f.run.number),
        before = Map.of(f.records.values);
    var allowed = true;
    f.records.beforeCommit = () async {
      allowed = false;
    };
    await expectLater(
      store.confirm(selected, consent: true, authorized: () => allowed),
      throwsStateError,
    );
    expect(f.records.values, before);
    f.records.beforeCommit = null;
    f.records.failCommit = true;
    await expectLater(
      store.confirm(selected, consent: true, authorized: () => true),
      throwsStateError,
    );
    expect(f.records.values, before);
  });

  test('native database reopen retains exact decision; corrupt decision is isolated without overwriting it', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final temp = await Directory.systemTemp.createTemp('asg-decision-');
    final path = '${temp.path}/records.db';
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase(path);
    var records = await StudioDatabase.migrate(db, prefs);
    for (final e in f.records.values.entries) {
      await records.setString(e.key, e.value);
    }
    final store = AgentTaskDecisionStore(records, project);
    final selected = store.select(f.session, f.run.number);
    final value = await store.confirm(
      selected,
      consent: true,
      authorized: () => true,
    );
    final raw = records.getString(value.storageKey);
    await db.close();
    db = await databaseFactoryIo.openDatabase(path);
    records = await StudioDatabase.migrate(db, prefs);
    expect(records.getString(value.storageKey), raw);
    expect(
      AgentTaskDecisionStore(
        records,
        project,
      ).load(f.session, f.run.number)!.fingerprint,
      value.fingerprint,
    );
    await db.close();
    db = await databaseFactoryIo.openDatabase(path);
    // Inject on-disk corruption outside the production store, then reopen it.
    await StoreRef<String, String>('records')
        .record(value.storageKey)
        .put(db, '{bad decision');
    await db.close();
    db = await databaseFactoryIo.openDatabase(path);
    records = await StudioDatabase.migrate(db, prefs);
    expect(() => records.getString(value.storageKey), throwsFormatException);
    expect(
      records.getString('studio.generation.v1.${project.id}'),
      f.records.getString('studio.generation.v1.${project.id}'),
    );
    await db.close();
    await temp.delete(recursive: true);
  });
}
