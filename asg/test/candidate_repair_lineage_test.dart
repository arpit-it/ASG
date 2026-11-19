// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/agent_session.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/candidate_reopen_context.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/models/repair_attempt.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/models/candidate_repair_lineage.dart';
import 'package:asg/models/selected_repair_request.dart';
import 'package:flutter_test/flutter_test.dart';

import 'selected_repair_request_test.dart' show selectedRepairFixture;

Future<CandidateRepairLineage> companion({int runNumber = 2}) async {
  final f = await selectedRepairFixture(formatted: true);
  return CandidateRepairLineage(
    projectId: f.origin.projectId,
    runNumber: runNumber,
    dispatchId: 'candidate-${f.origin.projectId}-$runNumber:3',
    repairRequestReference: SelectedRepairRequestReference.forProposed(
      f.origin,
      f.proposed,
    ),
    admissionSessionRecord: f.origin.requestSessionRecord,
    contextSha256: 'a' * 64,
  );
}

typedef LinkedRepairFixture = ({
  CandidateRepairLineage lineage,
  SelectedRepairRequest origin,
  RepairAttempt attempt,
  CandidateReopenContext context,
  CandidateVerificationRun run,
});
Future<LinkedRepairFixture> linkedRepairFixture({bool observed = true}) async {
  final f = await selectedRepairFixture(formatted: true);
  final failure = f.proposed.failure.snapshot;
  final working = GeneratedProject.fromJson({
    ...failure
        .copy(
          phase: SourceGenerationPhase.generated,
          checkpointVersion: 0,
          steps: [],
          outputs: {},
        )
        .toJson(),
    'directory': '/supplied-working',
  });
  final workingRaw = jsonEncode(working.toJson());
  final origin = SelectedRepairRequest.fromJson({
    ...f.origin.toJson(),
    'workingSha256': SelectedRepairRequest.fingerprint(workingRaw),
  });
  final attempt = RepairAttempt(
    number: f.proposed.number,
    startedAt: f.proposed.startedAt,
    failure: f.proposed.failure,
    status: RepairAttemptStatus.proposed,
    proposal: f.proposed.proposal,
    modelRequest: observed
        ? ModelRequestProvenance(
            model: f.origin.modelRequest.model,
            outputTokens: 4096,
            responseModel: 'supplied-candidate-response-model',
          )
        : ModelRequestProvenance(
            model: f.origin.modelRequest.model,
            outputTokens: 4096,
          ),
  );
  final proposal = SourceEditProposal.parse(
    attempt.toJson()['proposal'],
    originals: {for (final c in attempt.proposal!.changes) c.path: c.before},
    responseModel: attempt.modelRequest!.responseModel,
  );
  final reference = SelectedRepairRequestReference.forProposed(origin, attempt);
  final evidence = ApprovedSourceProposal(
    projectId: origin.projectId,
    boardTaskId: origin.boardTaskId,
    approval: origin.requestSession.approval,
    proposal: proposal,
    modelRequest: attempt.modelRequest,
  );
  final prepared = GeneratedProject.fromJson({
    ...working.toJson(),
    'directory': '/supplied-linked-candidate',
    'sourceRequest': attempt.modelRequest!.toJson(),
    'sources': {
      ...working.sources,
      for (final c in proposal.changes)
        c.path: SelectedRepairRequest.fingerprint(c.after),
    },
  });
  final basis = CandidateReopenBasis.capture(
    projectId: origin.projectId,
    workingRecord: workingRaw,
    working: working,
    sourceBase: failure,
    prepared: prepared,
    evidence: evidence,
  );
  final admission = origin.requestSession.observe(
    AgentSessionDispatch(
      boardTaskId: origin.boardTaskId,
      runNumber: 1,
      dispatchId: 'candidate-${origin.projectId}-1:3',
    ),
  );
  final run = CandidateVerificationRun(
    number: 2,
    startedAt: DateTime.utc(2026),
    snapshot: prepared.copy(phase: SourceGenerationPhase.verifying),
    finished: false,
    dispatchId: 'candidate-${origin.projectId}-2:3',
  );
  final session = admission.observe(
    AgentSessionDispatch(
      boardTaskId: origin.boardTaskId,
      runNumber: run.number,
      dispatchId: run.dispatchId!,
    ),
  );
  final context = CandidateReopenContext.bind(basis, session, run);
  final raw = jsonEncode(context.toJson());
  return (
    lineage: CandidateRepairLineage(
      projectId: origin.projectId,
      runNumber: run.number,
      dispatchId: run.dispatchId!,
      repairRequestReference: reference,
      admissionSessionRecord: const JsonEncoder.withIndent(' ')
          .convert(admission.toJson()),
      contextSha256: SelectedRepairRequest.fingerprint(raw),
    ),
    origin: origin,
    attempt: attempt,
    context: context,
    run: run,
  );
}

void main() {
  for (final observed in [true, false]) {
    test(
      'joint retained-record lineage preserves exact request and later admission (observed: $observed)',
      () async {
        final f = await linkedRepairFixture(observed: observed);
        final raw = jsonEncode(f.context.toJson());
        final value = CandidateRepairLineage.decode(f.lineage.encode());
        value.requireContext(raw, f.run, f.origin, f.attempt);
        expect(
          value.admissionSession.revision,
          f.origin.requestSession.revision + 1,
        );
        expect(f.context.session.revision, value.admissionSession.revision + 1);
        expect(value.admissionSessionRecord, contains('\n'));
        expect(
          value.admissionSessionRecord,
          isNot(f.origin.requestSessionRecord),
        );
        expect(f.context.basis.evidence.repairRequestReference, isNull);
        expect(
          f.attempt.modelRequest!.responseModel,
          observed ? isNotNull : isNull,
        );
      },
    );
  }
  test(
    'a new context digest cannot hide changed working or reviewed summary',
    () async {
      final f = await linkedRepairFixture();
      for (final field in ['working', 'summary']) {
        final changed =
            jsonDecode(jsonEncode(f.context.toJson())) as Map<String, dynamic>;
        final basis = changed['basis'] as Map<String, dynamic>;
        if (field == 'working') {
          basis['workingSha256'] = 'b' * 64;
        } else {
          ((basis['evidence'] as Map<String, dynamic>)['proposal']
                  as Map<String, dynamic>)['summary'] =
              'Different reviewed summary';
        }
        final raw = jsonEncode(changed);
        final value = CandidateRepairLineage.fromJson({
          ...f.lineage.toJson(),
          'contextSha256': SelectedRepairRequest.fingerprint(raw),
        });
        expect(
          () => value.requireContext(raw, f.run, f.origin, f.attempt),
          throwsFormatException,
          reason: field,
        );
      }
    },
  );
  test(
    'retargeted origin and altered attempt cannot inherit candidate proof',
    () async {
      final f = await linkedRepairFixture();
      final raw = jsonEncode(f.context.toJson());
      final other = SelectedRepairRequest.fromJson({
        ...f.origin.toJson(),
        'boardTaskId': 'Ttest',
      });
      final reference = SelectedRepairRequestReference.forProposed(
        other,
        f.attempt,
      );
      final value = CandidateRepairLineage.fromJson({
        ...f.lineage.toJson(),
        'repairRequestReference': reference.toJson(),
      });
      expect(
        () => value.requireContext(raw, f.run, other, f.attempt),
        throwsFormatException,
      );
      final changed = RepairAttempt.fromJson({
        ...f.attempt.toJson(),
        'startedAt': DateTime.utc(2025).toIso8601String(),
      });
      expect(
        () => f.lineage.requireContext(raw, f.run, f.origin, changed),
        throwsFormatException,
      );
    },
  );
  test(
    'admission must preserve prefix revision and append exactly one dispatch',
    () async {
      final f = await linkedRepairFixture();
      final raw = jsonEncode(f.context.toJson());
      for (final admission in [
        f.origin.requestSessionRecord,
        jsonEncode({
          ...f.lineage.admissionSession.toJson(),
          'revision': f.lineage.admissionSession.revision + 1,
        }),
      ]) {
        expect(
          () => CandidateRepairLineage.fromJson({
            ...f.lineage.toJson(),
            'admissionSessionRecord': admission,
          }).requireContext(raw, f.run, f.origin, f.attempt),
          throwsFormatException,
        );
      }
      expect(
        () => f.lineage.requireContext('$raw ', f.run, f.origin, f.attempt),
        throwsFormatException,
      );
    },
  );
  test(
    'codec keeps exact admission bytes and separate repair reference',
    () async {
      final value = await companion(runNumber: 35);
      final copy = CandidateRepairLineage.decode(value.encode());
      expect(copy.runNumber, 35);
      expect(copy.admissionSessionRecord, contains('\n'));
      expect(copy.admissionSessionRecord, value.admissionSessionRecord);
      expect(
        copy.repairRequestReference.encode(),
        value.repairRequestReference.encode(),
      );
      expect(
        copy.storageKey,
        '${CandidateRepairLineage.prefix}${value.projectId}.35',
      );
      expect(copy.toJson().keys, isNot(contains('requestSessionRecord')));
      expect(copy.toJson().length, 7);
    },
  );
  test(
    'foreign identities, unsafe ordinal and strict shape fail closed',
    () async {
      final value = await companion();
      for (final patch in <String, Object?>{
        'version': 2,
        'extra': true,
        'projectId': 'foreign',
        'runNumber': 9007199254740992,
        'dispatchId': 'candidate-foreign-2:3',
        'contextSha256': 'A' * 64,
        'repairRequestReference': {
          ...value.repairRequestReference.toJson(),
          'projectId': 'foreign',
        },
      }.entries) {
        expect(
          () => CandidateRepairLineage.fromJson({
            ...value.toJson(),
            patch.key: patch.value,
          }),
          throwsFormatException,
          reason: patch.key,
        );
      }
    },
  );
  test(
    'raw admission duplicate, cancelled and oversized records are rejected',
    () async {
      final value = await companion();
      for (final raw in [
        value.admissionSessionRecord.replaceFirst('{', '{"version":1,'),
        jsonEncode({
          ...value.admissionSession.toJson(),
          'cancellationRequested': true,
        }),
        ' ' * (AgentSession.maxEncodedBytes + 1),
      ]) {
        expect(
          () => CandidateRepairLineage.fromJson({
            ...value.toJson(),
            'admissionSessionRecord': raw,
          }),
          throwsFormatException,
        );
      }
    },
  );
  test(
    'canonical outer JSON bounds and private parse errors are sanitized',
    () async {
      final value = await companion();
      for (final raw in [
        ' ${value.encode()}',
        value.encode().replaceFirst('"version":1', '"version":1,"version":1'),
        ' ' * (CandidateRepairLineage.maxEncodedBytes + 1),
      ]) {
        expect(() => CandidateRepairLineage.decode(raw), throwsFormatException);
      }
      try {
        CandidateRepairLineage.decode('{"private-token":');
        fail('Expected malformed record');
      } on FormatException catch (error) {
        expect(error.source, isNull);
        expect('$error', isNot(contains('private-token')));
      }
    },
  );
}
