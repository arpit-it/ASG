// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/agent_session.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/candidate_request_lineage.dart';
import 'package:asg/models/candidate_reopen_context.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/models/session_proposal_reference.dart';
import 'package:asg/models/session_proposal_request.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/session_proposal_request_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'candidate_reopen_context_test.dart'
    show reopenFixture, reopenBefore, reopenAfter;
import 'planning_conversation_test.dart' show project;
import 'source_candidate_controller_test.dart' show AtomicRecords;

typedef LineageFixture = ({
  AtomicRecords records,
  SessionProposalRequest request,
  SessionProposalOrigin origin,
  CandidateReopenBasis basis,
  CandidateReopenContext context,
  CandidateVerificationRun run,
  CandidateRequestLineage lineage,
});

/// Supplied pure context only: no candidate dispatch/tool/session append is saved.
Future<LineageFixture> lineageFixture({
  int priorAdmissions = 0,
  bool formatted = false,
}) async {
  final f = await reopenFixture();
  final raw = formatted
      ? const JsonEncoder.withIndent('  ').convert(f.session.toJson())
      : jsonEncode(f.session.toJson());
  f.records.values[f.session.storageKey] = raw;
  final store = SessionProposalRequestStore(
    f.records,
    project.id,
    f.session.sessionId,
  );
  await store.reserve(
    project: project,
    binding: AgentSessionBinding.select(
      session: f.session,
      projectId: project.id,
      boardTaskId: 'Tanalyze',
    ),
    workingRecord: f.records.getString('studio.generation.v1.${project.id}')!,
    originals: const {'lib/main.dart': reopenBefore},
    modelRequest: const ModelRequestProvenance(
      model: 'supplied-request',
      outputTokens: 4096,
    ),
    authorize: () {},
  );
  final proposal = SourceEditProposal.parse(
    {
      'summary': 'Supplied lineage proposal',
      'changes': [
        {'path': 'lib/main.dart', 'before': reopenBefore, 'after': reopenAfter},
      ],
    },
    originals: const {'lib/main.dart': reopenBefore},
    responseModel: 'supplied-request',
  );
  await store.finish(
    SessionProposalRequestStatus.returnedValidated,
    proposal: proposal,
    authorizeReturn: () {},
  );
  final request = store.load().requests.single;
  final origin = SessionProposalOrigin(
    reference: SessionProposalRequestReference.fromRequest(request),
    requestSessionRecord: raw,
  );
  final evidence = ApprovedSourceProposal(
    projectId: project.id,
    boardTaskId: 'Tanalyze',
    approval: f.session.approval,
    proposal: proposal,
    modelRequest: request.modelRequest,
  );
  final basis = CandidateReopenBasis.capture(
    projectId: project.id,
    workingRecord: f.records.getString('studio.generation.v1.${project.id}')!,
    working: f.basis.working,
    sourceBase: f.basis.sourceBase,
    prepared: GeneratedProject.fromJson({
      ...f.basis.prepared.toJson(),
      'sourceRequest': request.modelRequest.toJson(),
    }),
    evidence: evidence,
  );
  var admission = f.session;
  for (var n = 1; n <= priorAdmissions; n++) {
    admission = admission.observe(
      AgentSessionDispatch(
        boardTaskId: 'Tanalyze',
        runNumber: n,
        dispatchId: 'candidate-${project.id}-$n:3',
      ),
    );
  }
  final number = priorAdmissions + 1;
  final run = CandidateVerificationRun(
    number: number,
    startedAt: DateTime.utc(2026, 11, 19),
    snapshot: basis.prepared,
    finished: false,
    dispatchId: 'candidate-${project.id}-$number:3',
  );
  final admitted = admission.observe(
    AgentSessionDispatch(
      boardTaskId: 'Tanalyze',
      runNumber: number,
      dispatchId: run.dispatchId!,
    ),
  );
  final context = CandidateReopenContext.bind(basis, admitted, run);
  final admissionRaw = formatted
      ? const JsonEncoder.withIndent(' ').convert(admission.toJson())
      : jsonEncode(admission.toJson());
  final lineage = CandidateRequestLineage(
    projectId: project.id,
    runNumber: number,
    dispatchId: run.dispatchId!,
    origin: origin,
    admissionSessionRecord: admissionRaw,
    contextSha256: SessionProposalRequestReference.fingerprint(
      jsonEncode(context.toJson()),
    ),
  );
  return (
    records: f.records,
    request: request,
    origin: origin,
    basis: basis,
    context: context,
    run: run,
    lineage: lineage,
  );
}

void main() {
  test('canonical companion retains exact origin and joins unchanged v1 context without effects', () async {
    final f = await lineageFixture();
    final before = Map.of(f.records.values);
    final raw = f.lineage.encode();
    final copy = CandidateRequestLineage.decode(raw);
    expect(copy.encode(), raw);
    expect(
      copy.storageKey,
      'studio.candidateRequestLineage.v1.${project.id}.1',
    );
    expect(
      copy
          .requireContext(jsonEncode(f.context.toJson()), f.run, f.request)
          .toJson(),
      f.context.toJson(),
    );
    expect(f.records.values, before);
    expect(f.records.getString(copy.storageKey), isNull);
    expect(f.context.toJson()['version'], 1);
    expect(f.basis.toJson()['version'], 1);
  });
  test(
    'retry retains original request while admission alone has one new append',
    () async {
      final f = await lineageFixture(priorAdmissions: 2);
      expect(f.origin.requestSession.dispatches, isEmpty);
      expect(f.lineage.admissionSession.dispatches, hasLength(2));
      expect(f.context.session.dispatches, hasLength(3));
      final copy = CandidateRequestLineage.decode(f.lineage.encode());
      copy.requireContext(jsonEncode(f.context.toJson()), f.run, f.request);
      expect(copy.origin.reference.number, 1);
      expect(
        () => AgentSessionBinding.select(
          session: f.origin.requestSession,
          projectId: project.id,
          boardTaskId: 'Tanalyze',
        ).admitted(f.context.session, f.run.dispatchId!),
        throwsFormatException,
      );
      final falseAdmission = CandidateRequestLineage.fromJson({
        ...f.lineage.toJson(),
        'admissionSessionRecord': f.origin.requestSessionRecord,
      });
      expect(
        () => falseAdmission.requireContext(
          jsonEncode(f.context.toJson()),
          f.run,
          f.request,
        ),
        throwsFormatException,
      );
    },
  );
  test('formatted raw snapshots survive outer canonical encoding without projection substitution', () async {
    final f = await lineageFixture(priorAdmissions: 1, formatted: true);
    final copy = CandidateRequestLineage.decode(f.lineage.encode());
    expect(copy.origin.requestSessionRecord, f.origin.requestSessionRecord);
    expect(copy.admissionSessionRecord, f.lineage.admissionSessionRecord);
    expect(
      f.request.sessionSha256,
      isNot(
        SessionProposalRequestReference.fingerprint(
          jsonEncode(f.origin.requestSession.toJson()),
        ),
      ),
    );
    copy.requireContext(jsonEncode(f.context.toJson()), f.run, f.request);
    expect(
      () => copy.requireContext(
        '${jsonEncode(f.context.toJson())} ',
        f.run,
        f.request,
      ),
      throwsFormatException,
    );
  });
  test('canonical companion rejects unknown fields, versions, duplicate keys and encoded bounds', () async {
    final f = await lineageFixture();
    final raw = f.lineage.encode();
    for (final bad in [
      ' $raw',
      raw.replaceFirst('"version":1', '"version":2'),
      raw.replaceFirst('"version":1', '"version":1,"version":1'),
      raw.replaceFirst('"runNumber":1', '"runNumber":1,"extra":true'),
      ' ' * (CandidateRequestLineage.maxEncodedBytes + 1),
    ]) {
      expect(() => CandidateRequestLineage.decode(bad), throwsFormatException);
    }
    for (final patch in <String, Object>{
      'projectId': 'other',
      'runNumber': 0,
      'dispatchId': 'candidate-other-1:3',
      'contextSha256': 'x' * 64,
      'admissionSessionRecord': ' ' * (AgentSession.maxEncodedBytes + 1),
    }.entries) {
      expect(
        () => CandidateRequestLineage.fromJson({
          ...f.lineage.toJson(),
          patch.key: patch.value,
        }),
        throwsFormatException,
        reason: patch.key,
      );
    }
  });
  test('matching entry hash alone cannot hide changed working, selected input, output or model', () async {
    final f = await lineageFixture();
    for (final patch in <String, Object>{
      'workingSha256': 'a' * 64,
      'sourceSha256': {
        ...f.request.sourceSha256,
        'lib/uncaptured.dart': 'a' * 64,
      },
      'returnedSha256': {'lib/main.dart': 'b' * 64},
      'modelRequest': const ModelRequestProvenance(
        model: 'other',
        outputTokens: 4096,
        responseModel: 'other',
      ).toJson(),
    }.entries) {
      final request = SessionProposalRequest.fromJson({
        ...f.request.toJson(),
        patch.key: patch.value,
      });
      final origin = SessionProposalOrigin(
        reference: SessionProposalRequestReference.fromRequest(request),
        requestSessionRecord: f.origin.requestSessionRecord,
      );
      final candidate = CandidateRequestLineage.fromJson({
        ...f.lineage.toJson(),
        'requestReference': origin.reference.toJson(),
      });
      expect(
        () => candidate.requireContext(
          jsonEncode(f.context.toJson()),
          f.run,
          request,
        ),
        throwsFormatException,
        reason: patch.key,
      );
    }
    final otherRun = CandidateVerificationRun(
      number: 99,
      startedAt: f.run.startedAt,
      snapshot: f.run.snapshot,
      finished: false,
      dispatchId: 'candidate-${project.id}-99:3',
    );
    expect(
      () => f.lineage.requireContext(
        jsonEncode(f.context.toJson()),
        otherRun,
        f.request,
      ),
      throwsFormatException,
    );
  });
}
