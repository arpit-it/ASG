// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/agent_session.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/candidate_request_lineage.dart';
import 'package:asg/models/candidate_reopen_context.dart';
import 'package:asg/models/session_proposal_reference.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/repair_attempt.dart';
import 'package:asg/models/selected_repair_request.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_admission.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/agent_session_run_status_store.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/candidate_repair_lineage_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/source_edit_proposer.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tools/fixtures/candidate_reopen.dart' show selectedRepairFixtureHome;

import 'candidate_reopen_context_test.dart' show reopenFixture, reopenBefore;
import 'candidate_repair_proposer_test.dart' show boundFailure, saveFailure;
import 'candidate_repair_lineage_test.dart' show linkedRepairFixture;
import 'planning_conversation_test.dart' show project;
import 'repair_request_context_test.dart'
    show SuppliedRepairContextProvider, suppliedRepairResponse;
import 'source_candidate_controller_test.dart' show AtomicRecords;

typedef RepairPreparationFixture = ({
  AtomicRecords records,
  AgentSession session,
  GeneratedProject failed,
  ApprovedSourceProposal evidence,
  String working,
});
Future<RepairPreparationFixture> repairPreparationFixture() async {
  final f = await reopenFixture();
  f.records.values[f.session.storageKey] = const JsonEncoder.withIndent(' ')
      .convert(f.session.toJson());
  final failed = GeneratedProject.fromJson({
    ...f.basis.sourceBase
        .copy(
          phase: SourceGenerationPhase.failed,
          checkpointVersion: 1,
          steps: boundFailure(f.records).steps,
          outputs: {},
        )
        .toJson(),
    'directory': '/supplied-failed-candidate',
  });
  await saveFailure(f.records, failed);
  final provider = SuppliedRepairContextProvider();
  final service = ApprovedSourceProposer(
    f.records,
    proposer: SourceEditProposer(createProvider: (_) => provider),
  );
  final working = f.records.getString('studio.generation.v1.${project.id}')!;
  final pending = service.propose(
    project: project,
    boardTaskId: 'Tanalyze',
    config: const LocalModelConfig(model: 'supplied-repair-model'),
    originals: const {'lib/main.dart': reopenBefore},
    repairCandidate: failed,
    repairSessionBinding: AgentSessionBinding.select(
      session: f.session,
      projectId: project.id,
      boardTaskId: 'Tanalyze',
    ),
    repairWorkingRecord: working,
  );
  await provider.entered.future;
  provider.stream.add(suppliedRepairResponse());
  unawaited(provider.stream.close());
  return (
    records: f.records,
    session: f.session,
    failed: failed,
    evidence: await pending,
    working: working,
  );
}

CandidateReopenBasis repairBasis(RepairPreparationFixture f) {
  final working = GeneratedProject.fromJson(
    jsonDecode(f.working) as Map<String, dynamic>,
  );
  final evidence = f.evidence;
  final normalized = ApprovedSourceProposal(
    projectId: evidence.projectId,
    boardTaskId: evidence.boardTaskId,
    approval: evidence.approval,
    proposal: evidence.proposal,
    modelRequest: evidence.modelRequest,
    repairRequestReference: evidence.repairRequestReference,
  );
  final prepared = GeneratedProject.fromJson({
    ...working
        .copy(
          phase: SourceGenerationPhase.generated,
          steps: [],
          outputs: {},
          resolution: {},
          pendingOperation: '',
          failedOperation: '',
          checkpointVersion: 0,
        )
        .toJson(),
    'directory': '/supplied-repair-copy',
    'sourceRequest': evidence.modelRequest!.toJson(),
    'sources': {
      ...working.sources,
      for (final c in evidence.proposal.changes)
        c.path: SelectedRepairRequest.fingerprint(c.after),
    },
  });
  return CandidateReopenBasis.capture(
    projectId: project.id,
    workingRecord: f.working,
    working: working,
    sourceBase: f.failed,
    prepared: prepared,
    evidence: normalized,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('new supplied repair-lineage browser fixture initializes', () async {
    await selectedRepairFixtureHome(lineageMode: true);
  });
  for (final outcome in [
    'success',
    'failed-write',
    'origin-race',
    'occupied',
    'initial-slot',
    'both',
  ]) {
    test('atomic repair candidate startup: $outcome', () async {
      final f = await repairPreparationFixture();
      final basis = repairBasis(f);
      final key = 'studio.candidateRepairLineage.v1.${project.id}.2';
      final initialKey = '${CandidateRequestLineage.prefix}${project.id}.2';
      if (outcome == 'occupied') f.records.values[key] = 'retained companion';
      if (outcome == 'initial-slot') {
        f.records.values[initialKey] = 'retained initial companion';
      }
      final before = Map<String, String>.of(f.records.values);
      if (outcome == 'failed-write') f.records.failCommit = true;
      var replacement = '';
      if (outcome == 'origin-race') {
        f.records.beforeCommit = () async {
          final originKey = '${SelectedRepairRequest.prefix}${project.id}.1';
          final origin = SelectedRepairRequest.decode(
            f.records.getString(originKey)!,
          );
          replacement = SelectedRepairRequest.fromJson({
            ...origin.toJson(),
            'workingSha256': 'f' * 64,
          }).encode();
          f.records.values[originKey] = replacement;
        };
      }
      var authorized = 0;
      final store = CandidateVerificationStore(f.records, project.id);
      final pending = store.start(
        basis.prepared.copy(phase: SourceGenerationPhase.verifying),
        () => authorized++,
        reopenBasis: basis,
        repairRequestReference: f.evidence.repairRequestReference,
        initialRequestOrigin: outcome != 'both'
            ? null
            : SessionProposalOrigin(
                reference: SessionProposalRequestReference(
                  projectId: project.id,
                  sessionId: f.session.sessionId,
                  number: 1,
                  requestSha256: 'a' * 64,
                ),
                requestSessionRecord: f.records.getString(
                  f.session.storageKey,
                )!,
              ),
        sessionAdmission: AgentSessionRunAdmission(
          f.records,
          project,
          AgentSessionBinding.select(
            session: f.session,
            projectId: project.id,
            boardTaskId: 'Tanalyze',
          ),
        ),
      );
      if (outcome == 'success') {
        final run = await pending;
        expect(run.number, 2);
        final review = CandidateRepairLineageStore(
          f.records,
          project.id,
        ).load(run)!;
        expect(
          review.lineage.repairRequestReference.encode(),
          f.evidence.repairRequestReference!.encode(),
        );
        expect(
          review.lineage.admissionSessionRecord,
          before[f.session.storageKey],
        );
        expect(review.lineage.admissionSessionRecord, contains('\n'));
        expect(
          f.records.getString(review.origin.storageKey),
          before[review.origin.storageKey],
        );
        expect(
          f.records.getString('studio.repairAttempts.v1.${project.id}'),
          before['studio.repairAttempts.v1.${project.id}'],
        );
        expect(f.records.getString(initialKey), isNull);
        expect(authorized, 1);
        final statuses = AgentSessionRunStatusStore(
          f.records,
          project.id,
        ).load(store.admittedSession!);
        expect(statuses.single.available, isTrue);
        expect(
          statuses.single.repairLineage!.lineage.repairRequestReference
              .encode(),
          f.evidence.repairRequestReference!.encode(),
        );
        expect(statuses.single.initialLineage, isNull);
        f.records.values[initialKey] = 'conflicting optional initial origin';
        final conflicted = AgentSessionRunStatusStore(
          f.records,
          project.id,
        ).load(store.admittedSession!).single;
        expect(conflicted.available, isTrue);
        expect(conflicted.repairLineage, isNull);
        expect(conflicted.initialLineage, isNull);
      } else {
        await expectLater(pending, throwsStateError);
        final expected = {...before};
        if (outcome == 'origin-race') {
          expected['${SelectedRepairRequest.prefix}${project.id}.1'] =
              replacement;
        }
        expect(f.records.values, expected);
        expect(authorized, 0);
      }
    });
  }
  test('native linked startup cold reopen survives withdrawal and isolates optional corruption', () async {
    final f = await repairPreparationFixture();
    final basis = repairBasis(f);
    final root = await Directory.systemTemp.createTemp(
      'asg-repair-linked-startup-',
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    try {
      final records = await StudioDatabase.migrate(db, prefs);
      for (final e in f.records.values.entries) {
        await records.setString(e.key, e.value);
      }
      final run = await CandidateVerificationStore(records, project.id).start(
        basis.prepared.copy(phase: SourceGenerationPhase.verifying),
        () {},
        reopenBasis: basis,
        repairRequestReference: f.evidence.repairRequestReference,
        sessionAdmission: AgentSessionRunAdmission(
          records,
          project,
          AgentSessionBinding.select(
            session: f.session,
            projectId: project.id,
            boardTaskId: 'Tanalyze',
          ),
        ),
      );
      final key = 'studio.candidateRepairLineage.v1.${project.id}.2';
      final raw = records.getString(key)!;
      await db.close();
      db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      final reopened = await StudioDatabase.migrate(db, prefs);
      await PlanApprovalStore(reopened)
          .save(project, ConversationStore(reopened).load(project.id), false);
      final workingKey = 'studio.generation.v1.${project.id}';
      await reopened.setString(
        workingKey,
        '${reopened.getString(workingKey)} ',
      );
      final history = CandidateRepairLineageStore(
        reopened,
        project.id,
      ).load(run)!;
      expect(history.lineage.encode(), raw);
      expect(
        history.lineage.repairRequestReference.encode(),
        f.evidence.repairRequestReference!.encode(),
      );
      final working = reopened.getString(workingKey);
      final origin = reopened.getString(history.origin.storageKey);
      await StoreRef<String, String>('records')
          .record(key)
          .put(db, 'private corrupt companion');
      await db.close();
      db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      final damaged = await StudioDatabase.migrate(db, prefs);
      expect(
        () => CandidateRepairLineageStore(damaged, project.id).load(run),
        throwsFormatException,
      );
      expect(damaged.getString(workingKey), working);
      expect(damaged.getString(history.origin.storageKey), origin);
      expect(
        CandidateVerificationStore(damaged, project.id).load().runs.length,
        2,
      );
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
  for (final changed in [
    'none',
    'origin',
    'repair-journal',
    'session',
    'working',
    'repair-slot',
    'initial-slot',
  ]) {
    test('native stale-adapter linked admission: $changed', () async {
      final f = await repairPreparationFixture();
      final basis = repairBasis(f);
      final root = await Directory.systemTemp.createTemp(
        'asg-repair-admission-',
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = await databaseFactoryIo.openDatabase(
        '${root.path}/records.db',
      );
      try {
        final first = await StudioDatabase.migrate(db, prefs);
        for (final e in f.records.values.entries) {
          await first.setString(e.key, e.value);
        }
        final second = await StudioDatabase.migrate(db, prefs);
        final originKey = '${SelectedRepairRequest.prefix}${project.id}.1';
        final journalKey = 'studio.repairAttempts.v1.${project.id}';
        switch (changed) {
          case 'origin':
            final origin = SelectedRepairRequest.decode(
              second.getString(originKey)!,
            );
            await second.setString(
              originKey,
              SelectedRepairRequest.fromJson({
                ...origin.toJson(),
                'workingSha256': 'f' * 64,
              }).encode(),
            );
          case 'repair-journal':
            await second.setString(
              journalKey,
              '${second.getString(journalKey)} ',
            );
          case 'session':
            await AgentSessionStore(
              second,
              project,
            ).requestCancellation(f.session);
          case 'working':
            final key = 'studio.generation.v1.${project.id}';
            await second.setString(key, '${second.getString(key)} ');
        }
        if (changed == 'repair-slot' || changed == 'initial-slot') {
          final prefix = changed == 'repair-slot'
              ? 'studio.candidateRepairLineage.v1.'
              : CandidateRequestLineage.prefix;
          await StoreRef<String, String>('records')
              .record('$prefix${project.id}.2')
              .put(db, 'retained occupied optional slot');
        }
        final nativeStore = StoreRef<String, String>('records');
        final before = {
          for (final r in await nativeStore.find(db)) r.key: r.value,
        };
        var authorized = 0;
        final pending = CandidateVerificationStore(first, project.id).start(
          basis.prepared.copy(phase: SourceGenerationPhase.verifying),
          () => authorized++,
          reopenBasis: basis,
          repairRequestReference: f.evidence.repairRequestReference,
          sessionAdmission: AgentSessionRunAdmission(
            first,
            project,
            AgentSessionBinding.select(
              session: f.session,
              projectId: project.id,
              boardTaskId: 'Tanalyze',
            ),
          ),
        );
        if (changed == 'none') {
          final run = await pending;
          expect(run.number, 2);
          expect(authorized, greaterThan(0));
          expect(
            CandidateRepairLineageStore(first, project.id).load(run),
            isNotNull,
          );
        } else {
          await expectLater(pending, throwsStateError);
          expect(authorized, 0);
          expect({
            for (final r in await nativeStore.find(db)) r.key: r.value,
          }, before);
          final reopened = await StudioDatabase.migrate(db, prefs);
          expect(
            CandidateVerificationStore(reopened, project.id).load().runs.length,
            1,
          );
          if (changed != 'repair-slot') {
            expect(
              reopened.getString(
                'studio.candidateRepairLineage.v1.${project.id}.2',
              ),
              isNull,
            );
          }
          expect(reopened.getString(journalKey), before[journalKey]);
        }
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    });
  }
  for (final changed in [
    'none',
    'origin',
    'repair-journal',
    'approval',
    'session',
    'working',
    'failure',
    'candidate-journal',
  ]) {
    test('native full preparation comparison: $changed', () async {
      final f = await repairPreparationFixture();
      final root = await Directory.systemTemp.createTemp(
        'asg-repair-preparation-',
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = await databaseFactoryIo.openDatabase(
        '${root.path}/records.db',
      );
      try {
        final first = await StudioDatabase.migrate(db, prefs);
        for (final e in f.records.values.entries) {
          await first.setString(e.key, e.value);
        }
        final second = await StudioDatabase.migrate(db, prefs);
        final originKey = '${SelectedRepairRequest.prefix}${project.id}.1';
        final journalKey = 'studio.repairAttempts.v1.${project.id}';
        switch (changed) {
          case 'origin':
            final origin = SelectedRepairRequest.decode(
              second.getString(originKey)!,
            );
            await second.setString(
              originKey,
              SelectedRepairRequest.fromJson({
                ...origin.toJson(),
                'workingSha256': 'f' * 64,
              }).encode(),
            );
          case 'repair-journal':
            await second.setString(
              journalKey,
              '${second.getString(journalKey)} ',
            );
          case 'approval':
            await PlanApprovalStore(
              second,
            ).save(project, ConversationStore(second).load(project.id), false);
          case 'session':
            await AgentSessionStore(
              second,
              project,
            ).requestCancellation(f.session);
          case 'working':
            final key = 'studio.generation.v1.${project.id}';
            await second.setString(key, '${second.getString(key)} ');
          case 'failure':
            final key = 'studio.sourceCandidate.v1.${project.id}';
            await second.setString(key, '${second.getString(key)} ');
          case 'candidate-journal':
            final key = 'studio.candidateChecks.v1.${project.id}';
            await second.setString(key, '${second.getString(key)} ');
        }
        final nativeStore = StoreRef<String, String>('records');
        final beforeGuard = {
          for (final r in await nativeStore.find(db)) r.key: r.value,
        };
        var authorized = 0;
        final store = CandidateRepairLineageStore(first, project.id);
        final guard = store.requirePreparation(
          project: project,
          admission: AgentSessionRunAdmission(
            first,
            project,
            AgentSessionBinding.select(
              session: f.session,
              projectId: project.id,
              boardTaskId: 'Tanalyze',
            ),
          ),
          evidence: f.evidence,
          sourceBase: f.failed,
          workingRecord: f.working,
          authorize: () => authorized++,
        );
        if (changed == 'none') {
          await guard;
          expect(authorized, 1);
          expect(first.getString(originKey), second.getString(originKey));
          expect(first.getString(journalKey), second.getString(journalKey));
        } else {
          await expectLater(guard, throwsStateError);
          expect(authorized, 0);
        }
        final reopened = await StudioDatabase.migrate(db, prefs);
        expect(reopened.getString(originKey), second.getString(originKey));
        expect(reopened.getString(journalKey), second.getString(journalKey));
        expect({
          for (final r in await nativeStore.find(db)) r.key: r.value,
        }, beforeGuard);
      } finally {
        await db.close();
        await root.delete(recursive: true);
      }
    });
  }
  test('historical join is independent of current state and refuses conflicting origins', () async {
    final f = await linkedRepairFixture();
    final records = AtomicRecords();
    await records.setString(f.origin.storageKey, f.origin.encode());
    await records.setString(
      'studio.repairAttempts.v1.${f.origin.projectId}',
      jsonEncode(RepairAttemptJournal([f.attempt]).toJson()),
    );
    await records.setString(
      f.context.storageKey,
      jsonEncode(f.context.toJson()),
    );
    await records.setString(
      'studio.candidateChecks.v1.${f.origin.projectId}',
      jsonEncode(
        CandidateVerificationJournal([f.attempt.failure, f.run]).toJson(),
      ),
    );
    await records.setString(f.lineage.storageKey, f.lineage.encode());
    final before = Map<String, String>.of(records.values);
    final store = CandidateRepairLineageStore(records, f.origin.projectId);
    final review = store.load(f.run)!;
    expect(review.lineage.encode(), f.lineage.encode());
    expect(review.origin.encode(), f.origin.encode());
    expect(records.values, before);
    records.values['${CandidateRequestLineage.prefix}${f.origin.projectId}.${f.run.number}'] =
        'conflicting optional bytes';
    expect(() => store.load(f.run), throwsStateError);
    expect(records.getString(f.lineage.storageKey), f.lineage.encode());
  });
}
