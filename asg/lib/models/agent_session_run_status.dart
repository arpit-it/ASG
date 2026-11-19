// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'agent_execution_checkpoint.dart';
import 'agent_session.dart';
import 'agent_session_publication.dart';
import 'agent_task_history.dart';
import 'source_generation.dart';

/// Correlated saved facts, never proof of external exit or task completion.
final class AgentSessionRunStatus {
  const AgentSessionRunStatus.unavailable(this.reference)
    : sourcePhase = null,
      executionPhase = null,
      pendingOperation = null,
      finished = null,
      taskHistory = null,
      publication = null;

  const AgentSessionRunStatus.recorded({
    required this.reference,
    required this.sourcePhase,
    required this.executionPhase,
    required this.pendingOperation,
    required this.finished,
    this.taskHistory,
    this.publication,
  });

  final AgentSessionDispatch reference;
  final SourceGenerationPhase? sourcePhase;
  final AgentExecutionPhase? executionPhase;
  final String? pendingOperation;
  final bool? finished;
  final AgentTaskHistory? taskHistory;
  final AgentSessionPublication? publication;
  bool get available => sourcePhase != null && executionPhase != null;
  bool get publicationUnavailable =>
      available &&
      executionPhase == AgentExecutionPhase.completed &&
      publication == null;
}
