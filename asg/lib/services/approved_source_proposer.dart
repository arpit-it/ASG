import 'dart:convert';

import '../models/approved_source_proposal.dart';
import '../models/build_plan.dart';
import '../models/local_model_config.dart';
import '../models/project.dart';
import '../models/requirements_board.dart';
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
    final current = PlanApprovalStore(records).requireCurrentApproval(project);
    if (evidence.projectId != project.id ||
        !evidence.approval.matches(current)) {
      throw StateError(
        'Source proposal approval changed. Request a new proposal.',
      );
    }
    _task(project, evidence.boardTaskId);
  }

  Future<ApprovedSourceProposal> propose({
    required StudioProject project,
    required String boardTaskId,
    required LocalModelConfig config,
    required Map<String, String> originals,
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
    _active = true;
    _cancelled = false;
    try {
      // Saved task/acceptance text is the instruction, not caller-supplied prose.
      final proposal = await _proposer.propose(
        config: config,
        instruction: jsonEncode({
          'task': task.toJson(),
          'requirement': requirement.toJson(),
          'requirementsRevision': board.revision,
        }),
        originals: originals,
      );
      if (_cancelled) throw StateError('Source proposal cancelled.');
      final evidence = ApprovedSourceProposal(
        projectId: project.id,
        boardTaskId: task.id,
        approval: approval,
        proposal: proposal,
      );
      // Includes changes while the provider was finishing transport cleanup.
      requireCurrent(project, evidence);
      return evidence;
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
