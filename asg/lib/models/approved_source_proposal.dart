import 'plan_approval.dart';
import 'source_edit_proposal.dart';

/// Review evidence only; this record grants no source-write or execution access.
class ApprovedSourceProposal {
  const ApprovedSourceProposal({
    required this.projectId,
    required this.boardTaskId,
    required this.approval,
    required this.proposal,
  });

  final String projectId, boardTaskId;
  final PlanApproval approval;
  final SourceEditProposal proposal;
}
