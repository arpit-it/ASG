import 'requirements_board.dart';
import 'build_task.dart';

enum RequirementCheckState {
  missing,
  stale,
  failed,
  incomplete,
  mappedChecksPassed,
}

class RequirementCheckResult {
  RequirementCheckResult(
    this.requirement,
    this.state,
    this.reason,
    List<String> taskIds,
    List<String> operationIds, {
    List<RequirementOperationEvidence> checks = const [],
  }) : checks = List.unmodifiable(checks),
       taskIds = List.unmodifiable(taskIds),
       operationIds = List.unmodifiable(operationIds);
  final ProjectRequirement requirement;
  final RequirementCheckState state;
  final String reason;
  final List<String> taskIds, operationIds;
  final List<RequirementOperationEvidence> checks;
  static const acceptanceStatus = 'Acceptance criteria: not verified';
  String get label => switch (state) {
    RequirementCheckState.missing => 'Missing evidence',
    RequirementCheckState.stale => 'Stale evidence',
    RequirementCheckState.failed => 'Failed checks',
    RequirementCheckState.incomplete => 'Incomplete checks',
    RequirementCheckState.mappedChecksPassed => 'Mapped checks passed',
  };
}

/// A projection of durable records, never a semantic acceptance verdict.
class RequirementCheckReport {
  RequirementCheckReport(
    this.requirementsRevision,
    List<RequirementCheckResult> results,
    this.evidenceJson,
  ) : results = List.unmodifiable(results);
  final int requirementsRevision;
  final List<RequirementCheckResult> results;
  final String evidenceJson;
  static const limits =
      'Saved command evidence only. No new checks, file inspection or inference ran. Mapped checks passed does not verify acceptance criteria or current artifact availability. Model Review remains advisory; manual task Done does not count as evidence.';
}

/// Only authored identifiers and result flags; raw command output is excluded.
class RequirementOperationEvidence {
  const RequirementOperationEvidence({
    required this.taskId,
    required this.boardTaskId,
    required this.operation,
    required this.status,
    this.exitCode,
    this.timedOut = false,
    this.cancelled = false,
    this.outputLimitExceeded = false,
  });
  final String taskId, boardTaskId;
  final BuildOperation operation;
  final BuildTaskStatus status;
  final int? exitCode;
  final bool timedOut, cancelled, outputLimitExceeded;
  String get summary => exitCode == null
      ? 'No saved command result'
      : 'Exit $exitCode; timed out: $timedOut; cancelled: $cancelled; output limit exceeded: $outputLimitExceeded';
  Map<String, Object?> toJson() => {
    'taskId': taskId,
    'boardTaskId': boardTaskId,
    'operation': operation.name,
    'status': status.name,
    'exitCode': exitCode,
    'timedOut': timedOut,
    'cancelled': cancelled,
    'outputLimitExceeded': outputLimitExceeded,
  };
}
