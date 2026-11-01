// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

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
  }) async {
    if (_active) {
      throw StateError('An approved source proposal is already active.');
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
    _active = true;
    _cancelled = false;
    final attempts = repairRun == null
        ? null
        : RepairAttemptStore(records, project.id);
    void authorizeRequest() {
      if (_cancelled) throw StateError('Source proposal cancelled.');
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
      if (repairRun != null) {
        await attempts!.reserve(repairRun, authorizeRequest);
      }
      authorizeRequest();
      // Saved task/acceptance text is the instruction, not caller-supplied prose.
      final proposal = await _proposer.propose(
        config: config,
        instruction: jsonEncode({
          'task': task.toJson(),
          'requirement': requirement.toJson(),
          'requirementsRevision': board.revision,
          if (repairRun != null) 'failedCheck': repairDiagnostics(repairRun),
        }),
        originals: originals,
      );
      if (_cancelled) throw StateError('Source proposal cancelled.');
      final evidence = ApprovedSourceProposal(
        projectId: project.id,
        boardTaskId: task.id,
        approval: approval,
        proposal: proposal,
        modelRequest: modelRequest,
        repairRun: repairRun,
      );
      // Includes changes while the provider was finishing transport cleanup.
      requireCurrent(project, evidence);
      await attempts?.finish(RepairAttemptStatus.proposed, proposal: proposal);
      if (_cancelled) throw StateError('Source proposal cancelled.');
      requireCurrent(project, evidence);
      return evidence;
    } catch (error) {
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
