// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/approved_source_proposal.dart';
import '../models/candidate_repair_lineage.dart';
import '../models/candidate_reopen_context.dart';
import '../models/candidate_request_lineage.dart';
import '../models/candidate_verification_run.dart';
import '../models/project.dart';
import '../models/repair_attempt.dart';
import '../models/selected_repair_request.dart';
import '../models/source_generation.dart';
import '../models/structured_proposal_json.dart';
import 'agent_session_admission.dart';
import 'record_storage.dart';
import 'repair_request_context.dart';

final class _RepairProof {
  _RepairProof(this.origin, this.attempt, this.expected);
  final SelectedRepairRequest origin;
  final RepairAttempt attempt;
  final Map<String, String?> expected;
}

/// Fixed-key input consumed only by the existing atomic startup transaction.
/// Creating it grants neither source access nor execution authority.
final class CandidateRepairLineageReservation {
  CandidateRepairLineageReservation._(
    this.records,
    this.lineage,
    Map<String, String?> expected,
  ) : expected = Map.unmodifiable(expected);
  final RecordStorage records;
  final CandidateRepairLineage lineage;
  final Map<String, String?> expected;
  String get key => lineage.storageKey;
  String get updated => lineage.encode();
  void requireCurrent() {
    if (expected.entries.any((e) => records.getString(e.key) != e.value)) {
      throw StateError('Repair candidate proof changed before admission.');
    }
  }
}

/// Explicit repair proof only. No latest/content matching or source restoration.
final class CandidateRepairLineageStore {
  CandidateRepairLineageStore(this.records, this.projectId);
  final RecordStorage records;
  final String projectId;
  String get _repairKey => 'studio.repairAttempts.v1.$projectId';

  static CandidateRepairLineage decode(String key, String raw) {
    final value = CandidateRepairLineage.decode(raw);
    if (value.storageKey != key) {
      throw const FormatException('Candidate repair lineage key changed.');
    }
    return value;
  }

  _RepairProof _proof(SelectedRepairRequestReference reference) {
    if (reference.projectId != projectId) {
      throw StateError('Repair reference belongs to another project.');
    }
    final key =
        '${SelectedRepairRequest.prefix}$projectId.${reference.attemptNumber}';
    final rawOrigin = records.getString(key);
    final rawJournal = records.getString(_repairKey);
    if (rawOrigin == null || rawJournal == null) {
      throw StateError('Exact repair origin or attempt is unavailable.');
    }
    final origin = SelectedRepairRequest.decode(rawOrigin);
    rejectDuplicateJsonMembers(rawJournal);
    final journal = RepairAttemptJournal.fromJson(
      jsonDecode(rawJournal) as Map<String, dynamic>,
    );
    final attempt = journal.attempts
        .where((a) => a.number == reference.attemptNumber)
        .single;
    if (origin.storageKey != key) {
      throw StateError('Repair origin key changed.');
    }
    reference.requireMatch(origin, attempt);
    return _RepairProof(origin, attempt, {
      key: rawOrigin,
      _repairKey: rawJournal,
    });
  }

  /// Durable read-only comparison of the FULL fixed repair context before copy.
  /// Call again after awaited work; cached callbacks alone do not prove freshness.
  Future<void> requirePreparation({
    required StudioProject project,
    required AgentSessionRunAdmission admission,
    required ApprovedSourceProposal evidence,
    required GeneratedProject sourceBase,
    required String workingRecord,
    required void Function() authorize,
  }) async {
    if (!identical(admission.records, records) ||
        admission.project.id != projectId ||
        project.id != projectId ||
        evidence.repairRequestReference == null ||
        evidence.initialRequestOrigin != null ||
        admission.binding.boardTaskId != evidence.boardTaskId) {
      throw StateError('Complete bound repair preparation proof is required.');
    }
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw StateError('Atomic storage is required for repair preparation.');
    }
    final reference = evidence.repairRequestReference!;
    final proof = _proof(reference);
    final context = RepairRequestContext.capture(
      records: records,
      project: project,
      failure: proof.attempt.failure,
      sessionBinding: admission.binding,
      workingRecord: workingRecord,
    );
    CandidateRepairLineage.requireEvidence(
      reference: reference,
      origin: proof.origin,
      attempt: proof.attempt,
      evidence: evidence,
      sourceBase: sourceBase,
      workingSha256: SelectedRepairRequest.fingerprint(workingRecord),
      admission: admission.binding.session,
    );
    final expected = {...context.expected, ...proof.expected};
    await storage.commitRecords(
      expected: expected,
      updates: const {},
      authorize: () {
        authorize();
        context.requireCurrent();
        if (expected.entries.any((e) => records.getString(e.key) != e.value)) {
          throw StateError('Repair preparation proof changed.');
        }
      },
    );
  }

  CandidateRepairLineageReservation prepare({
    required SelectedRepairRequestReference reference,
    required AgentSessionReservation admission,
    required CandidateReopenContext context,
    required CandidateVerificationRun run,
  }) {
    if (!identical(admission.request.records, records) ||
        admission.next.projectId != projectId) {
      throw StateError('Repair lineage belongs to another admission.');
    }
    admission.requireCurrent();
    final proof = _proof(reference);
    final lineage = CandidateRepairLineage(
      projectId: projectId,
      runNumber: run.number,
      dispatchId: run.dispatchId ?? '',
      repairRequestReference: reference,
      admissionSessionRecord: admission.expectedSession,
      contextSha256: SelectedRepairRequest.fingerprint(
        jsonEncode(context.toJson()),
      ),
    );
    lineage.requireContext(
      jsonEncode(context.toJson()),
      run,
      proof.origin,
      proof.attempt,
    );
    final reservation = CandidateRepairLineageReservation._(records, lineage, {
      ...proof.expected,
      lineage.storageKey: null,
      '${CandidateRequestLineage.prefix}$projectId.${run.number}': null,
    });
    reservation.requireCurrent();
    return reservation;
  }

  /// Exact historical join, independent of current working output and approval.
  CandidateRepairLineageReview? load(CandidateVerificationRun run) {
    final key = '${CandidateRepairLineage.prefix}$projectId.${run.number}';
    final raw = records.getString(key);
    if (raw == null) return null;
    final lineage = decode(key, raw);
    final initialKey =
        '${CandidateRequestLineage.prefix}$projectId.${run.number}';
    if (records.getString(initialKey) != null) {
      throw StateError('Conflicting candidate origins are unavailable.');
    }
    final proof = _proof(lineage.repairRequestReference);
    final journalKey = 'studio.candidateChecks.v1.$projectId';
    final journalRaw = records.getString(journalKey);
    final contextKey =
        '${CandidateReopenContext.prefix}$projectId.${run.number}';
    final contextRaw = records.getString(contextKey);
    if (journalRaw == null || contextRaw == null) {
      throw StateError('Exact candidate repair context is unavailable.');
    }
    final journal = CandidateVerificationJournal.fromJson(
      jsonDecode(journalRaw) as Map<String, dynamic>,
    );
    final retained = journal.runs.where((r) => r.number == run.number).single;
    if (jsonEncode(retained.toJson()) != jsonEncode(run.toJson())) {
      throw StateError('Candidate repair run changed.');
    }
    lineage.requireContext(contextRaw, run, proof.origin, proof.attempt);
    final expected = {
      ...proof.expected,
      key: raw,
      initialKey: null,
      journalKey: journalRaw,
      contextKey: contextRaw,
    };
    if (expected.entries.any((e) => records.getString(e.key) != e.value)) {
      throw StateError('Candidate repair lineage changed during its read.');
    }
    return CandidateRepairLineageReview(lineage, proof.origin, proof.attempt);
  }
}
