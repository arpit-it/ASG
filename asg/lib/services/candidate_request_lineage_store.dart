// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/candidate_request_lineage.dart';
import '../models/approved_source_proposal.dart';
import '../models/source_generation.dart';
import '../models/candidate_reopen_context.dart';
import '../models/candidate_verification_run.dart';
import '../models/session_proposal_reference.dart';
import 'agent_session_admission.dart';
import 'record_storage.dart';
import 'session_proposal_request_store.dart';

/// Fixed-key startup proof. Only candidate startup can commit this reservation.
final class CandidateRequestLineageReservation {
  CandidateRequestLineageReservation._(
    this.records,
    this.lineage,
    this.requestKey,
    this.expectedRequests,
  );
  final RecordStorage records;
  final CandidateRequestLineage lineage;
  final String requestKey, expectedRequests;
  String get key => lineage.storageKey;
  String get updated => lineage.encode();

  void requireCurrent() {
    if (records.getString(requestKey) != expectedRequests ||
        records.getString(key) != null) {
      throw StateError('Initial request proof changed during admission.');
    }
  }
}

/// Exact companion reads never select a latest request or grant execution rights.
final class CandidateRequestLineageStore {
  CandidateRequestLineageStore(this.records, this.projectId);
  final RecordStorage records;
  final String projectId;

  static CandidateRequestLineage decode(String key, String raw) {
    final value = CandidateRequestLineage.decode(raw);
    if (value.storageKey != key) {
      throw const FormatException('Candidate request lineage key changed.');
    }
    return value;
  }

  /// Validate captured initial evidence before preparation can copy any source.
  void requirePreparation({
    required SessionProposalOrigin origin,
    required AgentSessionRunAdmission admission,
    required ApprovedSourceProposal evidence,
    required GeneratedProject sourceBase,
    required String workingRecord,
  }) {
    if (!identical(admission.records, records) ||
        admission.project.id != projectId ||
        evidence.projectId != projectId ||
        evidence.repairRun != null ||
        admission.binding.boardTaskId != evidence.boardTaskId) {
      throw StateError('Initial proposal preparation identity changed.');
    }
    final raw = admission.requireCurrent();
    origin.requireExtension(SessionProposalOrigin.decodeSession(raw));
    final request = SessionProposalRequestStore(
      records,
      projectId,
      origin.reference.sessionId,
    ).referenced(origin.reference);
    origin.requireRequest(request);
    final returned = {
      for (final change in evidence.proposal.changes)
        change.path: SessionProposalRequestReference.fingerprint(change.after),
    };
    if (request.boardTaskId != evidence.boardTaskId ||
        records.getString('studio.generation.v1.$projectId') != workingRecord ||
        request.workingSha256 !=
            SessionProposalRequestReference.fingerprint(workingRecord) ||
        request.approvalSha256 !=
            SessionProposalRequestReference.fingerprint(
              jsonEncode(evidence.approval.toJson()),
            ) ||
        jsonEncode(request.modelRequest.toJson()) !=
            jsonEncode(evidence.modelRequest?.toJson()) ||
        request.modelRequest.responseModel != evidence.proposal.responseModel ||
        request.sourceSha256.entries.any(
          (e) => sourceBase.sources[e.key] != e.value,
        ) ||
        returned.length != request.returnedSha256.length ||
        returned.entries.any((e) => request.returnedSha256[e.key] != e.value)) {
      throw StateError('Initial proposal preparation proof changed.');
    }
  }

  CandidateRequestLineageReservation prepare({
    required SessionProposalOrigin origin,
    required AgentSessionReservation admission,
    required CandidateReopenContext context,
    required CandidateVerificationRun run,
  }) {
    if (!identical(admission.request.records, records) ||
        admission.next.projectId != projectId) {
      throw StateError('Initial lineage belongs to another admission.');
    }
    admission.requireCurrent();
    final requests = SessionProposalRequestStore(
      records,
      projectId,
      origin.reference.sessionId,
    );
    final requestRaw = records.getString(requests.key);
    if (requestRaw == null) {
      throw StateError('Initial request history is missing.');
    }
    final request = requests.referenced(origin.reference);
    final lineage = CandidateRequestLineage(
      projectId: projectId,
      runNumber: run.number,
      dispatchId: run.dispatchId ?? '',
      origin: origin,
      admissionSessionRecord: admission.expectedSession,
      contextSha256: SessionProposalRequestReference.fingerprint(
        jsonEncode(context.toJson()),
      ),
    );
    lineage.requireContext(jsonEncode(context.toJson()), run, request);
    final reservation = CandidateRequestLineageReservation._(
      records,
      lineage,
      requests.key,
      requestRaw,
    );
    reservation.requireCurrent();
    return reservation;
  }

  /// Historical proof needs neither current working output nor current approval.
  /// Null is legacy absence; malformed or inconsistent optional proof throws.
  CandidateRequestLineageReview? load(CandidateVerificationRun run) {
    final key = '${CandidateRequestLineage.prefix}$projectId.${run.number}';
    final raw = records.getString(key);
    if (raw == null) return null;
    final lineage = decode(key, raw);
    final journalKey = 'studio.candidateChecks.v1.$projectId';
    final journalRaw = records.getString(journalKey);
    if (journalRaw == null) {
      throw const FormatException('Referenced candidate run is missing.');
    }
    final journal = CandidateVerificationJournal.fromJson(
      jsonDecode(journalRaw) as Map<String, dynamic>,
    );
    final retained = journal.runs
        .where((value) => value.number == run.number)
        .single;
    if (jsonEncode(retained.toJson()) != jsonEncode(run.toJson())) {
      throw const FormatException('Referenced candidate run changed.');
    }
    final requests = SessionProposalRequestStore(
      records,
      projectId,
      lineage.origin.reference.sessionId,
    );
    final requestRaw = records.getString(requests.key);
    if (requestRaw == null) {
      throw const FormatException('Referenced request history is missing.');
    }
    final request = requests.referenced(lineage.origin.reference);
    final contextKey =
        '${CandidateReopenContext.prefix}$projectId.${run.number}';
    final contextRaw = records.getString(contextKey);
    if (contextRaw == null) {
      throw const FormatException('Referenced candidate context is missing.');
    }
    lineage.requireContext(contextRaw, run, request);
    if (records.getString(journalKey) != journalRaw ||
        records.getString(key) != raw ||
        records.getString(requests.key) != requestRaw ||
        records.getString(contextKey) != contextRaw) {
      throw StateError('Initial lineage changed during its read.');
    }
    return CandidateRequestLineageReview(lineage, request);
  }
}
