// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'agent_session.dart';
import 'agent_session_binding.dart';
import 'approved_source_proposal.dart';
import 'candidate_reopen_context.dart';
import 'candidate_verification_run.dart';
import 'repair_attempt.dart';
import 'source_edit_proposal.dart';
import 'source_generation.dart';
import 'selected_repair_request.dart';
import 'structured_proposal_json.dart';

AgentSession _admission(String raw) {
  try {
    if (utf8.encode(raw).length > AgentSession.maxEncodedBytes) {
      throw const FormatException();
    }
    rejectDuplicateJsonMembers(raw);
    return AgentSession.fromJson(jsonDecode(raw));
  } catch (_) {
    throw const FormatException('Repair admission session is unreadable.');
  }
}

/// Optional companion codec for the unchanged candidate context.
/// Shape validation alone proves neither a stored relationship nor authority.
final class CandidateRepairLineage {
  CandidateRepairLineage({
    required this.projectId,
    required this.runNumber,
    required this.dispatchId,
    required this.repairRequestReference,
    required this.admissionSessionRecord,
    required this.contextSha256,
  }) : admissionSession = _admission(admissionSessionRecord) {
    if (!AgentSessionTask.validId(projectId) ||
        runNumber < 1 ||
        runNumber > 9007199254740991 ||
        dispatchId != 'candidate-$projectId-$runNumber:3' ||
        dispatchId.length > 130 ||
        repairRequestReference.projectId != projectId ||
        admissionSession.projectId != projectId ||
        admissionSession.cancellationRequested ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(contextSha256) ||
        utf8.encode(encode()).length > maxEncodedBytes) {
      throw const FormatException('Invalid candidate repair lineage.');
    }
  }

  static const prefix = 'studio.candidateRepairLineage.v1.';
  static const maxEncodedBytes = 2 * 1024 * 1024;
  final String projectId, dispatchId, admissionSessionRecord, contextSha256;
  final int runNumber;
  final SelectedRepairRequestReference repairRequestReference;
  final AgentSession admissionSession;
  String get storageKey => '$prefix$projectId.$runNumber';

  Map<String, Object> toJson() => {
    'version': 1,
    'projectId': projectId,
    'runNumber': runNumber,
    'dispatchId': dispatchId,
    'repairRequestReference': repairRequestReference.toJson(),
    'admissionSessionRecord': admissionSessionRecord,
    'contextSha256': contextSha256,
  };
  String encode() => jsonEncode(toJson());

  factory CandidateRepairLineage.fromJson(Object? value) {
    const keys = {
      'version',
      'projectId',
      'runNumber',
      'dispatchId',
      'repairRequestReference',
      'admissionSessionRecord',
      'contextSha256',
    };
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !keys.every(value.containsKey) ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['runNumber'] is! int ||
        ![
          'projectId',
          'dispatchId',
          'admissionSessionRecord',
          'contextSha256',
        ].every((key) => value[key] is String)) {
      throw const FormatException('Invalid candidate repair lineage fields.');
    }
    return CandidateRepairLineage(
      projectId: value['projectId'] as String,
      runNumber: value['runNumber'] as int,
      dispatchId: value['dispatchId'] as String,
      repairRequestReference: SelectedRepairRequestReference.fromJson(
        value['repairRequestReference'],
      ),
      admissionSessionRecord: value['admissionSessionRecord'] as String,
      contextSha256: value['contextSha256'] as String,
    );
  }

  factory CandidateRepairLineage.decode(String raw) {
    if (utf8.encode(raw).length > maxEncodedBytes) {
      throw const FormatException(
        'Candidate repair lineage exceeds its bound.',
      );
    }
    Object? decoded;
    try {
      rejectDuplicateJsonMembers(raw);
      decoded = jsonDecode(raw);
    } catch (_) {
      throw const FormatException(
        'Candidate repair lineage JSON is unreadable.',
      );
    }
    final value = CandidateRepairLineage.fromJson(decoded);
    if (value.encode() != raw) {
      throw const FormatException(
        'Candidate repair lineage must be canonical.',
      );
    }
    return value;
  }

  static void _requireExtension(AgentSession original, AgentSession admission) {
    final added = admission.dispatches.length - original.dispatches.length;
    if (admission.projectId != original.projectId ||
        admission.sessionId != original.sessionId ||
        admission.cancellationRequested ||
        !admission.approval.matches(original.approval) ||
        jsonEncode(admission.tasks.toJson()) !=
            jsonEncode(original.tasks.toJson()) ||
        added < 0 ||
        admission.revision != original.revision + added ||
        jsonEncode(
              admission.dispatches
                  .take(original.dispatches.length)
                  .map((d) => d.toJson())
                  .toList(),
            ) !=
            jsonEncode(original.dispatches.map((d) => d.toJson()).toList())) {
      throw const FormatException(
        'Repair admission lost its request session prefix.',
      );
    }
  }

  static Map<String, Object> _proposal(SourceEditProposal value) => {
    'summary': value.summary,
    'changes': [
      for (final change in value.changes)
        {'path': change.path, 'before': change.before, 'after': change.after},
    ],
  };

  /// Pure relation checks only; durable/current validation belongs to the service.
  static void requireEvidence({
    required SelectedRepairRequestReference reference,
    required SelectedRepairRequest origin,
    required RepairAttempt attempt,
    required ApprovedSourceProposal evidence,
    required GeneratedProject sourceBase,
    required String workingSha256,
    required AgentSession admission,
  }) {
    reference.requireMatch(origin, attempt);
    _requireExtension(origin.requestSession, admission);
    final proposal = attempt.proposal;
    if (proposal == null ||
        origin.workingSha256 == null ||
        origin.workingSha256 != workingSha256 ||
        evidence.projectId != origin.projectId ||
        evidence.boardTaskId != origin.boardTaskId ||
        evidence.initialRequestOrigin != null ||
        (evidence.repairRequestReference != null &&
            evidence.repairRequestReference!.encode() != reference.encode()) ||
        (evidence.repairRun != null &&
            jsonEncode(evidence.repairRun!.toJson()) !=
                jsonEncode(attempt.failure.toJson())) ||
        !evidence.approval.matches(origin.requestSession.approval) ||
        jsonEncode(sourceBase.toJson()) !=
            jsonEncode(attempt.failure.snapshot.toJson()) ||
        jsonEncode(evidence.modelRequest?.toJson()) !=
            jsonEncode(attempt.modelRequest?.toJson()) ||
        evidence.proposal.responseModel !=
            attempt.modelRequest?.responseModel ||
        jsonEncode(_proposal(evidence.proposal)) !=
            jsonEncode(_proposal(proposal)) ||
        origin.sourceSha256.entries.any(
          (e) => sourceBase.sources[e.key] != e.value,
        )) {
      throw const FormatException(
        'Candidate evidence does not match its repair origin.',
      );
    }
  }

  /// Joins exact supplied history. Success grants no preparation or tool rights.
  CandidateReopenContext requireContext(
    String raw,
    CandidateVerificationRun run,
    SelectedRepairRequest origin,
    RepairAttempt attempt,
  ) {
    try {
      if (SelectedRepairRequest.fingerprint(raw) != contextSha256) {
        throw const FormatException();
      }
      final context = CandidateReopenContext.decode(raw);
      context.requireRun(run);
      if (context.basis.projectId != projectId ||
          context.runNumber != runNumber ||
          context.dispatchId != dispatchId ||
          run.number != runNumber ||
          run.dispatchId != dispatchId) {
        throw const FormatException();
      }
      requireEvidence(
        reference: repairRequestReference,
        origin: origin,
        attempt: attempt,
        evidence: context.basis.evidence,
        sourceBase: context.basis.sourceBase,
        workingSha256: context.basis.workingSha256,
        admission: admissionSession,
      );
      AgentSessionBinding.select(
        session: admissionSession,
        projectId: projectId,
        boardTaskId: origin.boardTaskId,
      ).admitted(context.session, dispatchId);
      return context;
    } catch (_) {
      throw const FormatException(
        'Exact candidate repair lineage is unavailable.',
      );
    }
  }
}

/// Detached, jointly checked history; no source or execution authority.
final class CandidateRepairLineageReview {
  const CandidateRepairLineageReview(this.lineage, this.origin, this.attempt);
  final CandidateRepairLineage lineage;
  final SelectedRepairRequest origin;
  final RepairAttempt attempt;
}
