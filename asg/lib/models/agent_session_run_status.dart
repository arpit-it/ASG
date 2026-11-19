// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'agent_execution_checkpoint.dart';
import 'agent_session.dart';
import 'agent_session_publication.dart';
import 'agent_task_history.dart';
import 'agent_task_decision.dart';
import 'source_generation.dart';
import 'candidate_request_lineage.dart';
import 'candidate_repair_lineage.dart';

/// Historical confirmation state for this exact saved reference.
enum AgentSessionDecisionState { absent, recorded, unavailable }

/// Correlated saved facts, never proof of external exit or task completion.
final class AgentSessionRunStatus {
  const AgentSessionRunStatus.unavailable(this.reference)
    : sourcePhase = null,
      executionPhase = null,
      pendingOperation = null,
      finished = null,
      taskHistory = null,
      publication = null,
      decision = null,
      initialLineage = null,
      repairLineage = null,
      decisionState = AgentSessionDecisionState.unavailable;

  const AgentSessionRunStatus.recorded({
    required this.reference,
    required this.sourcePhase,
    required this.executionPhase,
    required this.pendingOperation,
    required this.finished,
    this.taskHistory,
    this.initialLineage,
    this.repairLineage,
    this.publication,
    this.decision,
    this.decisionState = AgentSessionDecisionState.unavailable,
  });

  final AgentSessionDispatch reference;
  final SourceGenerationPhase? sourcePhase;
  final AgentExecutionPhase? executionPhase;
  final String? pendingOperation;
  final bool? finished;
  final AgentTaskHistory? taskHistory;
  final CandidateRequestLineageReview? initialLineage;
  final CandidateRepairLineageReview? repairLineage;
  final AgentSessionPublication? publication;
  final AgentTaskDecision? decision;
  final AgentSessionDecisionState decisionState;
  bool get available => sourcePhase != null && executionPhase != null;
  bool get publicationUnavailable =>
      available &&
      executionPhase == AgentExecutionPhase.completed &&
      publication == null;
}
