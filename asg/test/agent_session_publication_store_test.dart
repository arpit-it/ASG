// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/models/agent_execution_checkpoint.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/agent_session_publication.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/models/candidate_reopen_context.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/controllers/source_candidate_controller.dart';
import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/controllers/saved_candidate_recovery_controller.dart';
import 'package:asg/services/agent_session_admission.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/agent_session_publication_store.dart';
import 'package:asg/services/agent_session_run_status_store.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'agent_session_publication_test.dart' show publishedFixture;
import 'planning_conversation_test.dart' show project;
import 'candidate_reopen_context_test.dart' show reopenHash;
import 'saved_candidate_recovery_controller_test.dart'
    show admittedReopen, ReopenInspectionHost;

void main() {
  test('a later prepared bound publication creates its own outcome and retains the first verbatim', () async {
    final f = await publishedFixture(), records = f.fixture.records;
    final firstRaw = records.getString(f.publication.storageKey);
    final original = records.getString('studio.generation.v1.${project.id}')!;
    final priorEvidence = f.fixture.basis.evidence;
    final beforeText = priorEvidence.proposal.changes.single.after;
    final afterText = '$beforeText\n// second reviewed candidate';
    final evidence = ApprovedSourceProposal(
      projectId: project.id,
      boardTaskId: 'Tanalyze',
      approval: f.session.approval,
      proposal: SourceEditProposal.parse(
        {
          'summary': 'Second reviewed candidate',
          'changes': [
            {'path': 'lib/main.dart', 'before': beforeText, 'after': afterText},
          ],
        },
        originals: {'lib/main.dart': beforeText},
        responseModel: priorEvidence.proposal.responseModel,
      ),
      modelRequest: priorEvidence.modelRequest,
    );
    final prepared = GeneratedProject.fromJson({
      ...f.run.snapshot.toJson(),
      'directory': '/candidate-next',
      'phase': SourceGenerationPhase.generated.name,
      'sources': {
        ...f.run.snapshot.sources,
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
      workingRecord: original,
      working: f.run.snapshot,
      sourceBase: f.run.snapshot,
      prepared: prepared,
      evidence: evidence,
    );
    final owner = SourceGenerationController(
      project: project,
      definition: ApplicationStore(records).load(project).definition,
      store: SourceGenerationStore(records),
      host: ReopenInspectionHost(),
      selectedSession: f.session,
    );
    final candidate = SourceCandidateController(
      project: project,
      candidate: prepared,
      evidence: evidence,
      records: records,
      host: ReopenInspectionHost(),
      reopenBasis: basis,
      sessionBinding: AgentSessionBinding.select(
        session: f.session,
        projectId: project.id,
        boardTaskId: 'Tanalyze',
      ),
      publish: (value, host, authorize) => owner.promoteCandidate(
        value,
        host,
        authorize,
        expectedWorking: f.run.snapshot,
      ),
    );
    await candidate.verify(approved: true);
    expect(candidate.error, isNull);
    expect(await candidate.promote(approved: true), isTrue);
    final current = candidate.sessionBinding!.session;
    final before = Map.of(records.values);
    final statuses = AgentSessionRunStatusStore(
      records,
      project.id,
    ).load(current);
    final first = statuses
        .singleWhere((s) => s.reference.runNumber == f.run.number)
        .publication!;
    final second = statuses.last.publication!;
    expect(second.runNumber, f.run.number + 1);
    expect(first.storageKey, isNot(second.storageKey));
    expect(records.getString(first.storageKey), firstRaw);
    expect(second.originalWorkingSha256, first.publishedWorkingSha256);
    expect(second.publishedWorkingSha256, isNot(first.publishedWorkingSha256));
    expect(records.values, before);
    candidate.dispose();
    owner.dispose();
  });

  test('failed promotion, working/approval races and existing outcome publish no partial state', () async {
    for (final mode in ['commit', 'working', 'approval', 'existing']) {
      final a = await admittedReopen(), f = a.fixture;
      final hosts = <ReopenInspectionHost>[];
      final c = SavedCandidateRecoveryController(
        project: project,
        records: f.records,
        selectedSession: a.journal.admittedSession!,
        runNumber: 1,
        createHost: () {
          final host = ReopenInspectionHost();
          hosts.add(host);
          return host;
        },
      );
      await c.open();
      final candidate = c.candidate!;
      await candidate.verify(approved: true);
      expect(candidate.error, isNull);
      final run = CandidateVerificationStore(
        f.records,
        project.id,
      ).load().runs.last;
      final key =
          '${AgentSessionPublication.prefix}${project.id}.${run.number}';
      final executionKey =
          'studio.agentExecution.v1.candidate-${project.id}-${run.number}';
      final workingKey = 'studio.generation.v1.${project.id}';
      if (mode == 'existing') {
        final value = AgentSessionPublication.capture(
          session: candidate.sessionBinding!.session,
          run: run,
          originalWorkingRecord: f.records.getString(workingKey)!,
          publishedWorkingRecord: SourceGenerationStore(f.records)
              .encodeUpdate(project.id, run.snapshot),
          executionBefore: AgentExecutionCheckpoint.fromJson(
            jsonDecode(f.records.getString(executionKey)!),
          ),
        );
        f.records.values[key] = jsonEncode(value.toJson());
      }
      final before = Map.of(f.records.values);
      if (mode == 'commit') {
        f.records.failCommit = true;
      }
      if (mode == 'working' || mode == 'approval') {
        f.records.beforeCommit = () async {
          f.records.beforeCommit = null;
          if (mode == 'working') {
            f.records.values[workingKey] = '${before[workingKey]} ';
          } else {
            f.records.values.remove('studio.planApproval.v1.${project.id}');
          }
        };
      }
      expect(await candidate.promote(approved: true), isFalse);
      expect(f.records.getString(key), before[key]);
      expect(f.records.getString(executionKey), before[executionKey]);
      expect(
        f.records.getString('studio.generationPrevious.v1.${project.id}'),
        before['studio.generationPrevious.v1.${project.id}'],
      );
      expect(
        f.records.getString(workingKey),
        mode == 'working' ? '${before[workingKey]} ' : before[workingKey],
      );
      expect(hosts.last.server, isFalse);
      c.dispose();
    }
  });

  test('later admission preserves exact earlier publication without granting the new run an outcome', () async {
    final f = await publishedFixture(), records = f.fixture.records;
    final raw = records.getString(f.publication.storageKey);
    final journal = CandidateVerificationStore(records, project.id);
    final next = await journal.start(
      f.run.snapshot.copy(
        phase: SourceGenerationPhase.verifying,
        steps: const [],
        outputs: const {},
      ),
      () {},
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
    final before = Map.of(records.values);
    final statuses = AgentSessionRunStatusStore(
      records,
      project.id,
    ).load(journal.admittedSession!);
    expect(
      statuses
          .singleWhere((s) => s.reference.runNumber == f.run.number)
          .publication
          ?.toJson(),
      f.publication.toJson(),
    );
    expect(statuses.last.reference.runNumber, next.number);
    expect(statuses.last.publication, isNull);
    expect(records.getString(f.publication.storageKey), raw);
    expect(records.values, before);
  });

  test('read-only publication projection survives withdrawal and rotating working records', () async {
    final f = await publishedFixture(), records = f.fixture.records;
    final session = await AgentSessionStore(
      records,
      project,
    ).requestCancellation(f.session);
    records.values.remove('studio.planApproval.v1.${project.id}');
    records.values.remove('studio.generation.v1.${project.id}');
    records.values.remove('studio.generationPrevious.v1.${project.id}');
    final before = Map.of(records.values);
    final statuses = AgentSessionRunStatusStore(
      records,
      project.id,
    ).load(session);
    expect(statuses.last.publication?.toJson(), f.publication.toJson());
    expect(statuses.last.available, isTrue);
    expect(records.values, before);
  });

  test('missing corrupt and foreign publication preserve independent facts without backfill', () async {
    final f = await publishedFixture(), records = f.fixture.records;
    final key = f.publication.storageKey,
        original = records.getString(f.publication.storageKey)!;
    final foreign = f.publication.toJson();
    (foreign['session'] as Map)['sessionId'] = 'foreign';
    for (final raw in <String?>[
      null,
      '{private bad bytes',
      jsonEncode(foreign),
    ]) {
      if (raw == null) {
        records.values.remove(key);
      } else {
        records.values[key] = raw;
      }
      final before = Map.of(records.values);
      final status = AgentSessionRunStatusStore(
        records,
        project.id,
      ).load(f.session).last;
      expect(status.available, isTrue);
      expect(status.taskHistory, isNotNull);
      expect(status.publication, isNull);
      expect(records.values, before);
    }
    expect(
      () => StudioDatabase.validate(
        '${AgentSessionPublicationStore.prefix}foreign.2',
        original,
      ),
      throwsFormatException,
    );
  });

  test(
    'changed completed checkpoint or verified run cannot support publication',
    () async {
      final f = await publishedFixture(), records = f.fixture.records;
      final key =
          'studio.agentExecution.v1.${f.publication.executionAfter.taskId}';
      final execution = f.publication.executionAfter;
      final changed = AgentExecutionCheckpoint.fromJson({
        ...execution.toJson(),
        'revision': execution.revision + 1,
      });
      records.values[key] = jsonEncode(changed.toJson());
      final before = Map.of(records.values);
      expect(
        () => AgentSessionPublicationStore(
          records,
          project.id,
        ).load(session: f.session, run: f.run, execution: changed),
        throwsFormatException,
      );
      expect(records.values, before);
    },
  );

  test('actual native database reopen retains exact publication and read-only projection', () async {
    final f = await publishedFixture();
    final root = await Directory.systemTemp.createTemp(
      'asg-session-publication-',
    );
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    try {
      var native = await StudioDatabase.migrate(db, preferences);
      for (final entry in f.fixture.records.values.entries) {
        await native.setString(entry.key, entry.value);
      }
      final raw = native.getString(f.publication.storageKey);
      await db.close();
      db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      native = await StudioDatabase.migrate(db, preferences);
      final status = AgentSessionRunStatusStore(
        native,
        project.id,
      ).load(f.session).last;
      expect(jsonEncode(status.publication!.toJson()), raw);
      expect(native.getString(f.publication.storageKey), raw);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
