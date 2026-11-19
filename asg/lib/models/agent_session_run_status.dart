// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'agent_execution_checkpoint.dart';
import 'agent_session.dart';
import 'agent_task_history.dart';
import 'source_generation.dart';

/// Correlated saved facts, never proof of external exit or task completion.
final class AgentSessionRunStatus {
  const AgentSessionRunStatus.unavailable(this.reference)
    : sourcePhase = null,
      executionPhase = null,
      pendingOperation = null,
      finished = null,
      taskHistory = null;

  const AgentSessionRunStatus.recorded({
    required this.reference,
    required this.sourcePhase,
    required this.executionPhase,
    required this.pendingOperation,
    required this.finished,
    this.taskHistory,
  });

  final AgentSessionDispatch reference;
  final SourceGenerationPhase? sourcePhase;
  final AgentExecutionPhase? executionPhase;
  final String? pendingOperation;
  final bool? finished;
  final AgentTaskHistory? taskHistory;
  bool get available => sourcePhase != null && executionPhase != null;
}
