// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

enum AgentExecutionPhase {
  created,
  planning,
  awaitingApproval,
  executing,
  recovering,
  verifying,
  reviewing,
  completed,
  cancelled,
}

/// A persisted dispatch must be reconciled before it can be tried again.
final class AgentExecutionCheckpoint {
  AgentExecutionCheckpoint._(this.taskId, this.revision, this.phase);

  factory AgentExecutionCheckpoint.create(String taskId) {
    if (!isValidTaskId(taskId)) throw ArgumentError.value(taskId, 'taskId');
    return AgentExecutionCheckpoint._(taskId, 0, AgentExecutionPhase.created);
  }

  static bool isValidTaskId(String id) =>
      id.isNotEmpty &&
      id.length <= 128 &&
      !RegExp(r'[^a-zA-Z0-9_-]').hasMatch(id);

  final String taskId;
  final int revision;
  final AgentExecutionPhase phase;

  bool get requiresReconciliation =>
      phase == AgentExecutionPhase.executing ||
      phase == AgentExecutionPhase.recovering;

  AgentExecutionCheckpoint advance(AgentExecutionPhase next) {
    final allowed = switch (phase) {
      AgentExecutionPhase.created => {
        AgentExecutionPhase.planning,
        AgentExecutionPhase.cancelled,
      },
      AgentExecutionPhase.planning => {
        AgentExecutionPhase.awaitingApproval,
        AgentExecutionPhase.cancelled,
      },
      AgentExecutionPhase.awaitingApproval => {
        AgentExecutionPhase.executing,
        AgentExecutionPhase.cancelled,
      },
      AgentExecutionPhase.executing => {
        AgentExecutionPhase.recovering,
        AgentExecutionPhase.verifying,
      },
      AgentExecutionPhase.recovering => {
        AgentExecutionPhase.verifying,
        AgentExecutionPhase.awaitingApproval,
        AgentExecutionPhase.cancelled,
      },
      AgentExecutionPhase.verifying => {
        AgentExecutionPhase.reviewing,
        AgentExecutionPhase.awaitingApproval,
        AgentExecutionPhase.cancelled,
      },
      AgentExecutionPhase.reviewing => {
        AgentExecutionPhase.completed,
        AgentExecutionPhase.awaitingApproval,
        AgentExecutionPhase.cancelled,
      },
      AgentExecutionPhase.completed ||
      AgentExecutionPhase.cancelled => const <AgentExecutionPhase>{},
    };
    if (!allowed.contains(next)) {
      throw StateError('Invalid execution transition.');
    }
    return AgentExecutionCheckpoint._(taskId, revision + 1, next);
  }

  Map<String, Object> toJson() => {
    'version': 1,
    'taskId': taskId,
    'revision': revision,
    'phase': phase.name,
  };

  factory AgentExecutionCheckpoint.fromJson(Object? value) {
    if (value
        case {
          'version': 1,
          'taskId': final String taskId,
          'revision': final int revision,
          'phase': final String phaseName,
        }
        when value.length == 4 && isValidTaskId(taskId) && revision >= 0) {
      for (final phase in AgentExecutionPhase.values) {
        if (phase.name == phaseName &&
            (revision == 0) == (phase == AgentExecutionPhase.created)) {
          return AgentExecutionCheckpoint._(taskId, revision, phase);
        }
      }
    }
    throw const FormatException('Invalid execution checkpoint.');
  }
}
