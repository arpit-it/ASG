// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

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
  RequirementAcceptanceEvidence get acceptance =>
      RequirementAcceptanceEvidence(requirement);
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
      'criteria, declared check outcomes and task definitions. Review that text before sharing. Manual '
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

/// The board stores one free-form acceptance block per requirement. Treat it
/// atomically: splitting sentences or bullets would invent authored criteria.
class RequirementAcceptanceEvidence {
  const RequirementAcceptanceEvidence(this.requirement);
  final ProjectRequirement requirement;
  String get requirementSha256 =>
      sha256.convert(utf8.encode(jsonEncode(requirement.toJson()))).toString();
  static const label = 'Unmet acceptance evidence';
  static const reason =
      'No direct check result is recorded for this acceptance block. Generic '
      'operation results, manual task progress and advisory model Review '
      'do not verify it.';
  Map<String, Object?> toJson() => {
    'granularity': 'authoredAcceptanceBlock',
    'requirementId': requirement.id,
    'requirementSha256': requirementSha256,
    'text': requirement.acceptance,
    'status': 'unverified',
    'reason': reason,
    'declaredChecks': [
      for (final check in requirement.checks)
        {...check.toJson(), 'status': 'missing', 'result': null},
    ],
    'directChecks': <Object>[],
  };
}

/// Public content identity of a saved run, never proof of execution or freshness.
/// The input names are the fixed Flutter adapter's version-1 payload contract.
class RequirementRunIdentity {
  RequirementRunIdentity({
    required Map<String, String> sources,
    required Map<String, String> currentInputs,
    required String? approvalSha256,
  }) : approvalSha256 =
           approvalSha256 != null &&
               RegExp(r'^[a-f0-9]{64}$').hasMatch(approvalSha256)
           ? approvalSha256
           : null,
       sourceSha256 = manifestSha256(sources),
       savedInputSha256 = inputSha256(sources),
       currentInputSha256 = inputSha256(currentInputs);

  final String? sourceSha256, savedInputSha256, currentInputSha256;
  final String? approvalSha256;
  static const inputPaths = ['assets/app.json', 'asg_project.json'];

  /// Manifest order is irrelevant; names and digests are both part of identity.
  /// Empty/incomplete legacy evidence has no identity, not an empty-file hash.
  static String? manifestSha256(Map<String, String> manifest) {
    if (manifest.isEmpty ||
        manifest.values.any(
          (value) => !RegExp(r'^[a-f0-9]{64}$').hasMatch(value),
        )) {
      return null;
    }
    final names = manifest.keys.toList()..sort();
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({for (final name in names) name: manifest[name]}),
          ),
        )
        .toString();
  }

  static String? inputSha256(Map<String, String> manifest) =>
      inputPaths.any((name) => !manifest.containsKey(name))
      ? null
      : manifestSha256({for (final name in inputPaths) name: manifest[name]!});

  String? get savedRunSha256 =>
      sourceSha256 == null || savedInputSha256 == null || approvalSha256 == null
      ? null
      : sha256
            .convert(
              utf8.encode(
                jsonEncode({
                  'schema': 1,
                  'sourceSha256': sourceSha256,
                  'inputSha256': savedInputSha256,
                  'approvalSha256': approvalSha256,
                }),
              ),
            )
            .toString();

  Map<String, Object?> toJson() => {
    'schema': 1,
    'scope': 'Saved content identity only; not a direct check result or live artifact observation.',
    'savedRunSha256': savedRunSha256,
    'savedSourceSha256': sourceSha256,
    'savedInputSha256': savedInputSha256,
    'savedApprovalSha256': approvalSha256,
    'currentInputSha256': currentInputSha256,
  };
}
