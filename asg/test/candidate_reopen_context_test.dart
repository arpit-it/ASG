// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/agent_session.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/candidate_reopen_context.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approved_source_proposer_test.dart' show seed;
import 'planning_conversation_test.dart' show project;
import 'source_candidate_controller_test.dart' show AtomicRecords;

const reopenBefore = 'void main() {}';
const reopenAfter = 'void main() { /* reviewed */ }';
String reopenHash(String text) => sha256.convert(utf8.encode(text)).toString();

typedef ReopenFixture = ({
  AtomicRecords records,
  CandidateReopenBasis basis,
  AgentSession session,
});
Future<ReopenFixture> reopenFixture({
  String workingDirectory = '/working',
  String candidateDirectory = '/candidate',
}) async {
  final records = AtomicRecords();
  await seed(records);
  final approval = PlanApprovalStore(records).load(project.id)!;
  final board = RequirementsStore(records).load(project.id);
  final tasks = BuildPlan.parse(approval.content, board: board).tasks;
  final working = GeneratedProject(
    directory: workingDirectory,
    sdk: '/sdk',
    python: 'python3',
    confined: true,
    approval: approval,
    tasks: tasks,
    sources: {
      ...GenerationInput(
        project,
        ApplicationStore(records).load(project).definition,
      ).fingerprints,
      'lib/main.dart': reopenHash(reopenBefore),
    },
    outputs: {'index.html': 'a' * 64, 'main.dart.js': 'b' * 64},
    steps: [
      for (final task in tasks)
        GenerationStep(
          operation: task.operation.name,
          exitCode: 0,
          output: 'fixture',
        ),
    ],
    phase: SourceGenerationPhase.ready,
  );
  await SourceGenerationStore(records).save(project.id, working);
  final proposal = SourceEditProposal.parse(
    {
      'summary': 'Reviewed change',
      'changes': [
        {'path': 'lib/main.dart', 'before': reopenBefore, 'after': reopenAfter},
      ],
    },
    originals: {'lib/main.dart': reopenBefore},
    responseModel: 'fixture-response',
  );
  const request = ModelRequestProvenance(
    model: 'fixture-request',
    outputTokens: 4096,
    responseModel: 'fixture-response',
  );
  final evidence = ApprovedSourceProposal(
    projectId: project.id,
    boardTaskId: 'Tanalyze',
    approval: approval,
    proposal: proposal,
    modelRequest: request,
  );
  final prepared = GeneratedProject(
    directory: candidateDirectory,
    sdk: working.sdk,
    python: working.python,
    confined: true,
    approval: approval,
    tasks: tasks,
    sourceRequest: request,
    sources: {...working.sources, 'lib/main.dart': reopenHash(reopenAfter)},
  );
  final basis = CandidateReopenBasis.capture(
    projectId: project.id,
    workingRecord: records.getString('studio.generation.v1.${project.id}')!,
    working: working,
    sourceBase: working,
    prepared: prepared,
    evidence: evidence,
  );
  final session = await AgentSessionStore(
    records,
    project,
  ).create('reopen', board.tasks.map((task) => task.id).toList());
  return (records: records, basis: basis, session: session);
}

void main() {
  test(
    'context retains detached reviewed source and both model identities',
    () async {
      final f = await reopenFixture();
      final run = CandidateVerificationRun(
        number: 1,
        startedAt: DateTime.utc(2026),
        snapshot: f.basis.prepared,
        finished: false,
        dispatchId: 'candidate-${project.id}-1:3',
      );
      final session = f.session.observe(
        AgentSessionDispatch(
          boardTaskId: 'Tanalyze',
          runNumber: 1,
          dispatchId: run.dispatchId!,
        ),
      );
      final context = CandidateReopenContext.bind(f.basis, session, run);
      final copy = CandidateReopenContext.decode(jsonEncode(context.toJson()));
      expect(copy.storageKey, 'studio.candidateReopen.v1.${project.id}.1');
      expect(copy.basis.evidence.proposal.changes.single.before, reopenBefore);
      expect(copy.basis.evidence.modelRequest!.model, 'fixture-request');
      expect(copy.basis.evidence.proposal.responseModel, 'fixture-response');
      final detached = copy.toJson();
      (detached['basis'] as Map)['projectId'] = 'foreign';
      final sources = copy.basis.prepared.sources;
      expect(() => sources['lib/main.dart'] = 'f' * 64, throwsUnsupportedError);
      expect(
        copy.basis.prepared.sources['lib/main.dart'],
        reopenHash(reopenAfter),
      );
      expect(copy.basis.projectId, project.id);
      copy.requireRun(run);
      expect(
        f.records.getString(copy.storageKey),
        isNull,
      ); // The model cannot publish.
    },
  );

  test(
    'basis rejects changed source/configuration/provenance and unknown fields',
    () async {
      final f = await reopenFixture();
      for (final change in <void Function(Map<String, dynamic>)>[
        (v) => v['version'] = true,
        (v) => v['foreign'] = true,
        (v) => v['workingSha256'] = 'private',
        (v) => (v['prepared'] as Map)['foreign'] = true,
        (v) => ((v['prepared'] as Map)['sources'] as Map)['lib/main.dart'] =
            'a' * 64,
        (v) => ((v['sourceBase'] as Map)['sources'] as Map)['lib/main.dart'] =
            'b' * 64,
        (v) => ((v['sourceBase'] as Map)['sources'] as Map)['assets/app.json'] =
            'c' * 64,
        (v) => (v['prepared'] as Map)['sdk'] = '/other',
        (v) => (v['prepared'] as Map)['directory'] = '/working',
        (v) => (v['evidence'] as Map)['responseModel'] = 'other-model',
        (v) => (v['evidence'] as Map)['proposal'] = 'private malformed value',
        (v) => ((v['evidence'] as Map)['modelRequest'] as Map)['outputTokens'] =
            true,
      ]) {
        final value = f.basis.toJson();
        change(value);
        expect(
          () => CandidateReopenBasis.fromJson(value),
          throwsFormatException,
        );
      }
      expect(
        () => CandidateReopenBasis.fromJson({
          'private': 'x' * CandidateReopenBasis.maxEncodedBytes,
        }),
        throwsFormatException,
      );
    },
  );

  test('context refuses foreign admission, changed run and duplicate/oversized wire data', () async {
    final f = await reopenFixture();
    final run = CandidateVerificationRun(
      number: 1,
      startedAt: DateTime.utc(2026),
      snapshot: f.basis.prepared,
      finished: false,
      dispatchId: 'candidate-${project.id}-1:3',
    );
    final session = f.session.observe(
      AgentSessionDispatch(
        boardTaskId: 'Tanalyze',
        runNumber: 1,
        dispatchId: run.dispatchId!,
      ),
    );
    final context = CandidateReopenContext.bind(f.basis, session, run);
    for (final key in [
      'version',
      'runNumber',
      'dispatchId',
      'session',
      'basis',
    ]) {
      final value = context.toJson()..[key] = true;
      expect(
        () => CandidateReopenContext.fromJson(value),
        throwsFormatException,
      );
    }
    expect(
      () => CandidateReopenContext.bind(
        f.basis,
        session.requestCancellation(),
        run,
      ),
      throwsFormatException,
    );
    expect(
      () => context.requireRun(
        CandidateVerificationRun(
          number: 2,
          startedAt: run.startedAt,
          snapshot: run.snapshot,
          finished: false,
          dispatchId: run.dispatchId,
        ),
      ),
      throwsFormatException,
    );
    expect(
      () => CandidateReopenContext.decode('{"version":1,"version":1}'),
      throwsFormatException,
    );
    expect(
      () => CandidateReopenContext.decode(
        'x' * (CandidateReopenContext.maxEncodedBytes + 1),
      ),
      throwsFormatException,
    );
  });
}
