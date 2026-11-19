// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'agent_session.dart';
import 'agent_session_binding.dart';
import 'candidate_reopen_context.dart';
import 'candidate_verification_run.dart';
import 'session_proposal_reference.dart';
import 'session_proposal_request.dart';
import 'structured_proposal_json.dart';

/// Companion to the unchanged v1 context; jointly retained facts, not authority.
final class CandidateRequestLineage {
  CandidateRequestLineage({
    required this.projectId,
    required this.runNumber,
    required this.dispatchId,
    required this.origin,
    required this.admissionSessionRecord,
    required this.contextSha256,
  }) : admissionSession = SessionProposalOrigin.decodeSession(
         admissionSessionRecord,
       ) {
    if (!AgentSessionTask.validId(projectId) ||
        runNumber < 1 ||
        dispatchId != 'candidate-$projectId-$runNumber:3' ||
        origin.reference.projectId != projectId ||
        !SessionProposalRequestReference.isDigest(contextSha256)) {
      throw const FormatException('Invalid candidate request lineage.');
    }
    origin.requireExtension(admissionSession);
    if (utf8.encode(encode()).length > maxEncodedBytes) {
      throw const FormatException(
        'Candidate request lineage exceeds its bound.',
      );
    }
  }
  static const prefix = 'studio.candidateRequestLineage.v1.';
  static const maxEncodedBytes = 4 * 1024 * 1024;
  final String projectId, dispatchId, admissionSessionRecord, contextSha256;
  final int runNumber;
  final SessionProposalOrigin origin;
  final AgentSession admissionSession;
  String get storageKey => '$prefix$projectId.$runNumber';
  Map<String, Object> toJson() => {
    'version': 1,
    'projectId': projectId,
    'runNumber': runNumber,
    'dispatchId': dispatchId,
    'requestReference': origin.reference.toJson(),
    'requestSessionRecord': origin.requestSessionRecord,
    'admissionSessionRecord': admissionSessionRecord,
    'contextSha256': contextSha256,
  };
  String encode() => jsonEncode(toJson());

  factory CandidateRequestLineage.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 8 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['runNumber'] is! int ||
        ![
          'projectId',
          'dispatchId',
          'requestSessionRecord',
          'admissionSessionRecord',
          'contextSha256',
        ].every((key) => value[key] is String)) {
      throw const FormatException('Invalid candidate request lineage.');
    }
    return CandidateRequestLineage(
      projectId: value['projectId'] as String,
      runNumber: value['runNumber'] as int,
      dispatchId: value['dispatchId'] as String,
      origin: SessionProposalOrigin(
        reference: SessionProposalRequestReference.fromJson(
          value['requestReference'],
        ),
        requestSessionRecord: value['requestSessionRecord'] as String,
      ),
      admissionSessionRecord: value['admissionSessionRecord'] as String,
      contextSha256: value['contextSha256'] as String,
    );
  }
  factory CandidateRequestLineage.decode(String raw) {
    if (utf8.encode(raw).length > maxEncodedBytes) {
      throw const FormatException(
        'Candidate request lineage exceeds its bound.',
      );
    }
    final decoded = jsonDecode(raw);
    rejectDuplicateJsonMembers(raw);
    final value = CandidateRequestLineage.fromJson(decoded);
    if (value.encode() != raw) {
      throw const FormatException(
        'Candidate request lineage must be canonical.',
      );
    }
    return value;
  }

  /// Verifies only the exact supplied retained records, never current approval.
  CandidateReopenContext requireContext(
    String raw,
    CandidateVerificationRun run,
    SessionProposalRequest request,
  ) {
    origin.requireRequest(request);
    if (SessionProposalRequestReference.fingerprint(raw) != contextSha256) {
      throw const FormatException('Retained candidate context bytes changed.');
    }
    final context = CandidateReopenContext.decode(raw);
    context.requireRun(run);
    if (context.basis.projectId != projectId ||
        context.runNumber != runNumber ||
        context.dispatchId != dispatchId ||
        context.basis.workingSha256 != request.workingSha256) {
      throw const FormatException(
        'Candidate lineage run or working identity changed.',
      );
    }
    AgentSessionBinding.select(
      session: admissionSession,
      projectId: projectId,
      boardTaskId: request.boardTaskId,
    ).admitted(context.session, dispatchId);
    final basis = context.basis;
    final evidence = basis.evidence;
    final returned = {
      for (final change in evidence.proposal.changes)
        change.path: SessionProposalRequestReference.fingerprint(change.after),
    };
    if (evidence.boardTaskId != request.boardTaskId ||
        SessionProposalRequestReference.fingerprint(
              jsonEncode(evidence.approval.toJson()),
            ) !=
            request.approvalSha256 ||
        jsonEncode(evidence.modelRequest?.toJson()) !=
            jsonEncode(request.modelRequest.toJson()) ||
        evidence.proposal.responseModel != request.modelRequest.responseModel ||
        request.sourceSha256.entries.any(
          (e) => basis.sourceBase.sources[e.key] != e.value,
        ) ||
        returned.length != request.returnedSha256.length ||
        returned.entries.any((e) => request.returnedSha256[e.key] != e.value)) {
      throw const FormatException(
        'Candidate does not match the referenced initial return.',
      );
    }
    return context;
  }
}

/// Detached proof for rendering. Constructing it grants no tool permission.
final class CandidateRequestLineageReview {
  const CandidateRequestLineageReview(this.lineage, this.request);
  final CandidateRequestLineage lineage;
  final SessionProposalRequest request;
}
