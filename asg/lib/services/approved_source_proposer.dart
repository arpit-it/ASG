// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/agent_session_binding.dart';
import '../models/session_proposal_request.dart';
import 'agent_session_admission.dart';
import 'session_proposal_request_store.dart';
import '../models/repair_attempt.dart';
import '../models/model_request_provenance.dart';
import 'repair_attempt_store.dart';
import '../models/approved_source_proposal.dart';
import '../models/build_plan.dart';
import '../models/local_model_config.dart';
import '../models/project.dart';
import '../models/requirements_board.dart';
import '../models/source_generation.dart';
import 'application_store.dart';
import 'candidate_repair_evidence.dart';
import 'generation_input.dart';
import 'plan_approval_store.dart';
import 'record_storage.dart';
import 'requirements_store.dart';
import 'source_edit_proposer.dart';

/// Binds review-only inference to durable approval and a mapped board task.
/// The raw proposer remains a transport/parser, never an authorization boundary.
class ApprovedSourceProposer {
  ApprovedSourceProposer(this.records, {SourceEditProposer? proposer})
    : _proposer = proposer ?? SourceEditProposer();

  final RecordStorage records;
  final SourceEditProposer _proposer;
  bool _active = false, _cancelled = false;

  DevelopmentTask _task(StudioProject project, String id) {
    final approval = PlanApprovalStore(records).requireCurrentApproval(project);
    final board = RequirementsStore(records).load(project.id);
    final plan = BuildPlan.parse(approval.content, board: board);
    final matches = board.tasks.where((t) => t.id == id).toList();
    if (matches.length != 1 || !plan.tasks.any((t) => t.boardTaskId == id)) {
      throw StateError(
        'Select a board task mapped in the current approved Plan.',
      );
    }
    return matches.single;
  }

  /// Call again before showing or using retained evidence. No writes are allowed.
  void requireCurrent(StudioProject project, ApprovedSourceProposal evidence) {
    evidence.modelRequest?.validate();
    if (evidence.modelRequest != null &&
        evidence.modelRequest!.outputTokens !=
            SourceEditProposer.outputTokens) {
      throw const FormatException('Invalid source request ceiling.');
    }
    final current = PlanApprovalStore(records).requireCurrentApproval(project);
    if (evidence.projectId != project.id ||
        !evidence.approval.matches(current)) {
      throw StateError(
        'Source proposal approval changed. Request a new proposal.',
      );
    }
    _task(project, evidence.boardTaskId);
    final run = evidence.repairRun;
    if (run != null) {
      requireRepairFailure(records, project.id, run.snapshot, expected: run);
      _requireRepairApproval(project, run.snapshot);
    }
  }

  void _requireRepairApproval(
    StudioProject project,
    GeneratedProject candidate,
  ) {
    final approval = PlanApprovalStore(records).requireCurrentApproval(project);
    if (candidate.approval == null ||
        !candidate.approval!.matches(approval) ||
        !BuildPlan.parse(
          approval.content,
          board: RequirementsStore(records).load(project.id),
        ).matchesTasks(candidate.tasks) ||
        GenerationInput(
              project,
              ApplicationStore(records).load(project).definition,
            ).compare(candidate) !=
            GeneratedSnapshotStatus.current) {
      throw StateError('Failed candidate approval or project inputs changed.');
    }
  }

  Future<ApprovedSourceProposal> propose({
    required StudioProject project,
    required String boardTaskId,
    required LocalModelConfig config,
    required Map<String, String> originals,
    GeneratedProject? repairCandidate,
    AgentSessionBinding? sessionBinding,
    String? requestWorkingRecord,
    void Function()? authorizeSession,
  }) async {
    if (_active) {
      throw StateError('An approved source proposal is already active.');
    }
    if (sessionBinding != null &&
        (repairCandidate != null ||
            requestWorkingRecord == null ||
            authorizeSession == null ||
            sessionBinding.boardTaskId != boardTaskId)) {
      throw StateError('Complete initial session request context is required.');
    }
    final approval = PlanApprovalStore(records).requireCurrentApproval(project);
    final task = _task(project, boardTaskId);
    final board = RequirementsStore(records).load(project.id);
    final requirement = board.requirements.singleWhere(
      (r) => r.id == task.requirementId,
    );
    final repairRun = repairCandidate == null
        ? null
        : requireRepairFailure(records, project.id, repairCandidate);
    if (repairCandidate != null) {
      _requireRepairApproval(project, repairCandidate);
    }
    config.endpoint;
    final modelRequest = ModelRequestProvenance(
      model: config.model,
      outputTokens: SourceEditProposer.outputTokens,
    );
    modelRequest.validate();
    final instruction = jsonEncode({
      'task': task.toJson(),
      'requirement': requirement.toJson(),
      'requirementsRevision': board.revision,
      if (repairRun != null) 'failedCheck': repairDiagnostics(repairRun),
    });
    final snapshot = Map<String, String>.unmodifiable(originals);
    if (sessionBinding != null) {
      SourceEditProposer.validateInput(instruction, snapshot);
    }
    final initial = sessionBinding == null
        ? null
        : SessionProposalRequestStore(
            records,
            project.id,
            sessionBinding.session.sessionId,
          );
    _active = true;
    _cancelled = false;
    final attempts = repairRun == null
        ? null
        : RepairAttemptStore(records, project.id);
    void authorizeRequest() {
      if (_cancelled) throw StateError('Source proposal cancelled.');
      if (sessionBinding != null) {
        authorizeSession!();
        AgentSessionRunAdmission(
          records,
          project,
          sessionBinding,
        ).requireCurrent();
        if (records.getString('studio.generation.v1.${project.id}') !=
            requestWorkingRecord) {
          throw StateError(
            'Working build changed during initial source request.',
          );
        }
      }
      final current = PlanApprovalStore(records)
          .requireCurrentApproval(project);
      if (!approval.matches(current)) {
        throw StateError('Source approval changed.');
      }
      _task(project, boardTaskId);
      if (repairRun != null) {
        requireRepairFailure(
          records,
          project.id,
          repairRun.snapshot,
          expected: repairRun,
        );
        _requireRepairApproval(project, repairRun.snapshot);
      }
    }

    try {
      if (initial != null) {
        await initial.reserve(
          project: project,
          binding: sessionBinding!,
          workingRecord: requestWorkingRecord!,
          originals: snapshot,
          modelRequest: modelRequest,
          authorize: authorizeRequest,
        );
      }
      if (repairRun != null) {
        await attempts!.reserve(
          repairRun,
          authorizeRequest,
          modelRequest: modelRequest,
        );
      }
      authorizeRequest();
      // Saved task/acceptance text is the instruction, not caller-supplied prose.
      final proposal = await _proposer.propose(
        config: config,
        instruction: instruction,
        originals: snapshot,
      );
      if (_cancelled) throw StateError('Source proposal cancelled.');
      final evidence = ApprovedSourceProposal(
        projectId: project.id,
        boardTaskId: task.id,
        approval: approval,
        proposal: proposal,
        modelRequest: modelRequest.withResponseModel(proposal.responseModel),
        repairRun: repairRun,
      );
      // Includes changes while the provider was finishing transport cleanup.
      requireCurrent(project, evidence);
      if (initial != null) authorizeRequest();
      await attempts?.finish(RepairAttemptStatus.proposed, proposal: proposal);
      await initial?.finish(
        SessionProposalRequestStatus.returnedValidated,
        proposal: proposal,
        authorizeReturn: authorizeRequest,
      );
      if (_cancelled) throw StateError('Source proposal cancelled.');
      if (initial != null) authorizeRequest();
      requireCurrent(project, evidence);
      if (initial == null) return evidence;
      final origin = initial.returnedOrigin;
      if (origin == null) {
        throw StateError('Initial return origin was not persisted.');
      }
      return ApprovedSourceProposal(
        projectId: evidence.projectId,
        boardTaskId: evidence.boardTaskId,
        approval: evidence.approval,
        proposal: evidence.proposal,
        modelRequest: evidence.modelRequest,
        initialRequestOrigin: origin,
      );
    } catch (error) {
      await initial?.finish(
        _cancelled
            ? SessionProposalRequestStatus.cancelledLocally
            : SessionProposalRequestStatus.failedLocally,
      );
      await attempts?.finish(
        _cancelled ? RepairAttemptStatus.cancelled : RepairAttemptStatus.failed,
      );
      rethrow;
    } finally {
      _active = false;
    }
  }

  Future<void> cancel() async {
    if (!_active) return;
    _cancelled = true;
    await _proposer.cancel();
  }
}
