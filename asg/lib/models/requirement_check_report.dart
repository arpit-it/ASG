import 'requirements_board.dart';

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
    List<String> operationIds,
  ) : taskIds = List.unmodifiable(taskIds),
      operationIds = List.unmodifiable(operationIds);
  final ProjectRequirement requirement;
  final RequirementCheckState state;
  final String reason;
  final List<String> taskIds, operationIds;
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
