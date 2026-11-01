// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'plan_approval.dart';
import 'model_request_provenance.dart';
import 'source_edit_proposal.dart';
import 'candidate_verification_run.dart';

/// Review evidence only; this record grants no source-write or execution access.
class ApprovedSourceProposal {
  const ApprovedSourceProposal({
    required this.projectId,
    required this.boardTaskId,
    required this.approval,
    required this.proposal,
    this.repairRun,
    this.modelRequest,
  });

  final ModelRequestProvenance? modelRequest;
  final String projectId, boardTaskId;
  final PlanApproval approval;
  final SourceEditProposal proposal;
  final CandidateVerificationRun? repairRun;
}
