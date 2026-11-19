// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'agent_task_decision.dart';

/// Exact local recorded identities only; never compatibility or permission.
enum PrerequisitePreparationState {
  directRecordedLink,
  noDirectMatch,
  unavailable,
}

final class PrerequisitePreparationEvidence {
  const PrerequisitePreparationEvidence(this.reference, this.state);
  final AgentTaskDecisionReference reference;
  final PrerequisitePreparationState state;
}

/// A detached read-only projection of one retained dependent decision.
final class PrerequisitePreparationReview {
  PrerequisitePreparationReview({
    required this.decisionSha256,
    required this.runNumber,
    required Iterable<PrerequisitePreparationEvidence> prerequisites,
  }) : prerequisites = List.unmodifiable(prerequisites);

  final String decisionSha256;
  final int runNumber;
  final List<PrerequisitePreparationEvidence> prerequisites;
}
