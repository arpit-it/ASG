import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'artifact_inspection.dart';
import 'requirements_board.dart';
import 'build_task.dart';
import 'source_generation.dart';

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
    this.evidenceJson, {
    this.savedProject,
    this.snapshotFingerprint = '',
  }) : results = List.unmodifiable(results);
  final int requirementsRevision;
  final List<RequirementCheckResult> results;
  final String evidenceJson;
  final GeneratedProject? savedProject;
  final String snapshotFingerprint;

  /// Public evidence only: do not export the private snapshot fingerprint.
  String evidenceWithInspection(RequirementArtifactObservation? observation) =>
      const JsonEncoder.withIndent('  ').convert({
        'savedEvidence': jsonDecode(evidenceJson),
        'artifactInspection': observation == null
            ? null
            : {
                'outcome': observation.outcome.name,
                'observedAt': observation.observedAt.toUtc().toIso8601String(),
                'savedEvidenceSha256': sha256
                    .convert(utf8.encode(evidenceJson))
                    .toString(),
                'scope':
                    'Read-only point-in-time observation of recorded source '
                    'and output fingerprints. No commands or inference ran. '
                    'This is not a semantic acceptance verdict or a guarantee '
                    'that files remain unchanged.',
              },
      });

  static const authoredEvidenceNotice =
      'Expanded and copied evidence includes your requirement titles, acceptance '
      'criteria and task definitions. Review that text before sharing. Manual '
      'task status is progress only; acceptance criteria remain unverified.';

  static const limits =
      'Mapped checks passed describes saved command evidence, not acceptance criteria or current artifact availability. Inspect current artifacts separately to compare recorded source and output fingerprints. Inspection is read-only and reflects files only when inspected; it does not run commands or inference. Model Review remains advisory; manual task Done does not count as evidence.';
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

/// Transient observation accepted only after checking the durable snapshot.
class RequirementArtifactObservation {
  const RequirementArtifactObservation(this.outcome, this.observedAt);
  final ArtifactInspection outcome;
  final DateTime observedAt;
}
