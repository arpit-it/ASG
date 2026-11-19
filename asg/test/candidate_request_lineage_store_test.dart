// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/services/studio_database.dart';
import 'package:asg/services/agent_session_run_status_store.dart';
import 'package:asg/services/session_proposal_request_store.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/models/session_proposal_request.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/services/agent_session_admission.dart';
import 'package:asg/services/candidate_request_lineage_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'candidate_request_lineage_test.dart'
    show lineageFixture, LineageFixture;
import 'planning_conversation_test.dart' show project;

AgentSessionRunAdmission admission(LineageFixture f) =>
    AgentSessionRunAdmission(
      f.records,
      project,
      AgentSessionBinding.select(
        session: f.origin.requestSession,
        projectId: project.id,
        boardTaskId: f.request.boardTaskId,
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'journal growth retains the explicitly selected older identical return',
    () async {
      final f = await lineageFixture();
      final requests = SessionProposalRequestStore(
        f.records,
        project.id,
        f.request.sessionId,
      );
      await requests.reserve(
        project: project,
        binding: admission(f).binding,
        workingRecord: f.records.getString(
          'studio.generation.v1.${project.id}',
        )!,
        originals: {
          for (final change in f.basis.evidence.proposal.changes)
            change.path: change.before,
        },
        modelRequest: const ModelRequestProvenance(
          model: 'supplied-request',
          outputTokens: 4096,
        ),
        authorize: () {},
      );
      await requests.finish(
        SessionProposalRequestStatus.returnedValidated,
        proposal: f.basis.evidence.proposal,
        authorizeReturn: () {},
      );
      expect(requests.load().requests, hasLength(2));
      final store = CandidateVerificationStore(f.records, project.id);
      final run = await store.start(
        f.basis.prepared.copy(
          phase: SourceGenerationPhase.verifying,
          steps: [],
        ),
        () {},
        sessionAdmission: admission(f),
        reopenBasis: f.basis,
        initialRequestOrigin: f.origin,
      );
      expect(
        CandidateRequestLineageStore(
          f.records,
          project.id,
        ).load(run)!.request.number,
        1,
      );
      expect(requests.returnedOrigin!.reference.number, 2);
      expect(
        requests.returnedOrigin!.reference.requestSha256,
        isNot(f.origin.reference.requestSha256),
      );
    },
  );
  test('native durable request race refuses stale startup and close/reopen retains exact proof', () async {
    final f = await lineageFixture(formatted: true);
    final root = await Directory.systemTemp.createTemp('asg-lineage-native-');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    try {
      var native = await StudioDatabase.migrate(db, prefs);
      for (final e in f.records.values.entries) {
        await native.setString(e.key, e.value);
      }
      final stale = await StudioDatabase.migrate(db, prefs);
      final requestKey =
          'studio.sessionProposalRequests.v1.${project.id}.${f.request.sessionId}';
      final raw = native.getString(requestKey)!;
      final metadata = SessionProposalRequest.fromJson({
        ...f.request.toJson(),
        'startedAt': f.request.startedAt
            .subtract(const Duration(seconds: 1))
            .toIso8601String(),
      });
      await native.setString(
        requestKey,
        SessionProposalRequestJournal([metadata]).encode(),
      );
      final staleStore = CandidateVerificationStore(stale, project.id);
      await expectLater(
        staleStore.start(
          f.basis.prepared.copy(
            phase: SourceGenerationPhase.verifying,
            steps: [],
          ),
          () {},
          reopenBasis: f.basis,
          initialRequestOrigin: f.origin,
          sessionAdmission: AgentSessionRunAdmission(
            stale,
            project,
            admission(f).binding,
          ),
        ),
        throwsStateError,
      );
      expect(
        await StoreRef<String, String>('records')
            .record(f.lineage.storageKey)
            .get(db),
        isNull,
      );
      expect(
        await StoreRef<String, String>('records')
            .record('studio.candidateChecks.v1.${project.id}')
            .get(db),
        isNull,
      );
      await native.setString(requestKey, raw);
      final store = CandidateVerificationStore(native, project.id);
      final run = await store.start(
        f.basis.prepared.copy(
          phase: SourceGenerationPhase.verifying,
          steps: [],
        ),
        () {},
        reopenBasis: f.basis,
        initialRequestOrigin: f.origin,
        sessionAdmission: AgentSessionRunAdmission(
          native,
          project,
          admission(f).binding,
        ),
      );
      final companion = native.getString(f.lineage.storageKey);
      final context = native.getString(f.context.storageKey);
      await db.close();
      db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      native = await StudioDatabase.migrate(db, prefs);
      final review = CandidateRequestLineageStore(
        native,
        project.id,
      ).load(run)!;
      expect(
        review.lineage.origin.requestSessionRecord,
        f.origin.requestSessionRecord,
      );
      expect(native.getString(f.lineage.storageKey), companion);
      expect(native.getString(f.context.storageKey), context);
      expect(native.getString(requestKey), raw);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });

  test('atomic startup retains formatted origin and historical reads ignore current approval and working', () async {
    final f = await lineageFixture(formatted: true);
    final working = f.records.getString('studio.generation.v1.${project.id}');
    final store = CandidateVerificationStore(f.records, project.id);
    final run = await store.start(
      f.basis.prepared.copy(phase: SourceGenerationPhase.verifying, steps: []),
      () {},
      sessionAdmission: admission(f),
      reopenBasis: f.basis,
      initialRequestOrigin: f.origin,
    );
    final reader = CandidateRequestLineageStore(f.records, project.id);
    final saved = reader.load(run)!;
    final overview = AgentSessionRunStatusStore(f.records, project.id);
    expect(
      overview
          .load(store.admittedSession!)
          .single
          .initialLineage!
          .request
          .number,
      1,
    );
    final valid = f.records.values[saved.lineage.storageKey]!;
    f.records.values[saved.lineage.storageKey] = '{private malformed';
    final partial = overview.load(store.admittedSession!).single;
    expect(partial.available, isTrue);
    expect(partial.taskHistory, isNotNull);
    expect(partial.initialLineage, isNull);
    f.records.values[saved.lineage.storageKey] = valid;
    expect(
      saved.lineage.origin.requestSessionRecord,
      f.origin.requestSessionRecord,
    );
    expect(saved.lineage.admissionSessionRecord, f.origin.requestSessionRecord);
    expect(saved.request.number, f.request.number);
    expect(f.records.getString('studio.generation.v1.${project.id}'), working);
    final companion = f.records.getString(saved.lineage.storageKey);
    await store.checkpoint(
      run.snapshot.copy(pendingOperation: 'resolve'),
      () {},
    );
    expect(f.records.getString(saved.lineage.storageKey), companion);
    f.records.values.remove('studio.planApproval.v1.${project.id}');
    f.records.values['studio.generation.v1.${project.id}'] = 'changed output';
    final before = Map.of(f.records.values);
    expect(
      reader.load(store.load().runs.single)!.request.number,
      f.request.number,
    );
    expect(f.records.values, before);
  });
  test('changed request during startup refuses all admission writes', () async {
    final f = await lineageFixture();
    final key =
        'studio.sessionProposalRequests.v1.${project.id}.${f.request.sessionId}';
    final before = Map.of(f.records.values);
    f.records.beforeCommit = () async {
      f.records.beforeCommit = null;
      f.records.values[key] = '${before[key]} ';
    };
    final store = CandidateVerificationStore(f.records, project.id);
    await expectLater(
      store.start(
        f.basis.prepared.copy(
          phase: SourceGenerationPhase.verifying,
          steps: [],
        ),
        () {},
        sessionAdmission: admission(f),
        reopenBasis: f.basis,
        initialRequestOrigin: f.origin,
      ),
      throwsStateError,
    );
    expect(f.records.values, {...before, key: '${before[key]} '});
    expect(store.admittedSession, isNull);
    expect(store.load().runs, isEmpty);
  });
  test(
    'failed commit and existing companion cannot partially admit a run',
    () async {
      for (final existing in [false, true]) {
        final f = await lineageFixture();
        if (existing) {
          f.records.values[f.lineage.storageKey] = f.lineage.encode();
        } else {
          f.records.failCommit = true;
        }
        final before = Map.of(f.records.values);
        final store = CandidateVerificationStore(f.records, project.id);
        await expectLater(
          store.start(
            f.basis.prepared.copy(
              phase: SourceGenerationPhase.verifying,
              steps: [],
            ),
            () {},
            sessionAdmission: admission(f),
            reopenBasis: f.basis,
            initialRequestOrigin: f.origin,
          ),
          throwsStateError,
        );
        expect(f.records.values, before);
        expect(store.load().runs, isEmpty);
      }
    },
  );
  test(
    'legacy absence and changed optional proof never infer a link or write',
    () async {
      final f = await lineageFixture();
      final reader = CandidateRequestLineageStore(f.records, project.id);
      expect(reader.load(f.run), isNull);
      f.records.values[f.lineage.storageKey] = f.lineage.encode();
      f.records.values['studio.candidateChecks.v1.${project.id}'] = jsonEncode(
        CandidateVerificationJournal([f.run]).toJson(),
      );
      f.records.values[f.context.storageKey] = jsonEncode(f.context.toJson());
      expect(reader.load(f.run), isNotNull);
      final before = Map.of(f.records.values);
      f.records.values[f.context.storageKey] =
          '${before[f.context.storageKey]} ';
      expect(() => reader.load(f.run), throwsFormatException);
      expect(f.records.values, {
        ...before,
        f.context.storageKey: '${before[f.context.storageKey]} ',
      });
      f.records.values[f.context.storageKey] = before[f.context.storageKey]!;
      f.records.values[f.lineage.storageKey] = '{private invalid';
      expect(() => reader.load(f.run), throwsFormatException);
      expect(
        () => CandidateRequestLineageStore.decode('wrong', f.lineage.encode()),
        throwsFormatException,
      );
    },
  );
}
