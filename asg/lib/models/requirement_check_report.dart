// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'artifact_inspection.dart';
import 'manual_check_observation.dart';
import 'named_check_observation.dart';
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
    this.revisionIdentity,
    this.savedInputsCurrent = false,
    List<ManualCheckObservation> manualObservations = const [],
    List<NamedCheckObservation> namedObservations = const [],
  }) : results = List.unmodifiable(results),
       manualObservations = List.unmodifiable(manualObservations),
       namedObservations = List.unmodifiable(namedObservations);
  final List<NamedCheckObservation> namedObservations;
  NamedCheckObservation? namedObservationFor(
    String requirementId,
    String checkId,
  ) => namedObservations
      .where((v) => v.requirementId == requirementId && v.checkId == checkId)
      .firstOrNull;
  bool namedObservationCurrent(NamedCheckObservation value) =>
      canRecordManualObservation &&
      value.runSha256 == revisionIdentity?.savedRunSha256 &&
      results.any(
        (r) =>
            r.requirement.id == value.requirementId &&
            r.acceptance.requirementSha256 == value.requirementSha256 &&
            r.requirement.checks.any(
              (c) =>
                  c.id == value.checkId &&
                  c.type == AcceptanceCheckType.automated &&
                  c.target?.file == value.result.target.file &&
                  c.target?.name == value.result.target.name,
            ),
      );

  /// Each authored declaration resolves only its own evidence kind and identity.
  /// Generic operations never supply a direct result or acceptance verdict.
  RequirementDirectCheckEvidence directCheck(
    ProjectRequirement requirement,
    AcceptanceCheckDefinition check,
  ) {
    if (check.type == AcceptanceCheckType.automated) {
      final value = namedObservationFor(requirement.id, check.id);
      return RequirementDirectCheckEvidence(
        check,
        value == null
            ? 'missing'
            : !namedObservationCurrent(value)
            ? 'stale'
            : value.result.passed
            ? 'savedTargetPassed'
            : 'savedTargetNotPassed',
        value?.toJson(),
      );
    }
    if (check.type == AcceptanceCheckType.manual) {
      final value = observationFor(requirement.id, check.id);
      return RequirementDirectCheckEvidence(
        check,
        value == null
            ? 'missing'
            : !observationCurrent(value)
            ? 'stale'
            : value.passed
            ? 'manuallyReportedPassed'
            : 'manuallyReportedFailed',
        value?.toJson(),
      );
    }
    return RequirementDirectCheckEvidence(check, 'advisoryOnly', null);
  }

  Map<String, Object?> acceptanceEvidence(RequirementCheckResult result) => {
    ...result.acceptance.toJson(),
    'criteria': [
      for (final criterion in result.requirement.criteria)
        criterionEvidence(result.requirement, criterion),
    ],
    'declaredChecks': [
      for (final check in result.requirement.checks)
        directCheck(result.requirement, check).toJson(),
    ],
    'directChecks': [
      for (final check in result.requirement.checks)
        if (directCheck(result.requirement, check).result != null)
          directCheck(result.requirement, check).toJson(),
    ],
  };

  /// Summarizes saved mapped checks, never semantic acceptance or live files.
  CriterionCheckSummary criterionCheckSummary(
    ProjectRequirement requirement,
    AcceptanceCriterionDefinition criterion,
  ) {
    if (criterion.checkIds.isEmpty) return CriterionCheckSummary.unmapped;
    final checks = <RequirementDirectCheckEvidence>[];
    for (final id in criterion.checkIds) {
      final declaration = requirement.checks
          .where((c) => c.id == id)
          .firstOrNull;
      // Invalid/transient callers must fail closed instead of vacuously passing.
      if (declaration == null) return CriterionCheckSummary.missing;
      checks.add(directCheck(requirement, declaration));
    }
    if (checks.any((c) => c.status == 'stale')) {
      return CriterionCheckSummary.stale;
    }
    if (checks.any(
      (c) =>
          c.status == 'savedTargetNotPassed' ||
          c.status == 'manuallyReportedFailed',
    )) {
      return CriterionCheckSummary.failed;
    }
    if (checks.any((c) => c.status == 'missing')) {
      return CriterionCheckSummary.missing;
    }
    if (checks.every((c) => c.status == 'savedTargetPassed')) {
      return CriterionCheckSummary.automatedChecksPassed;
    }
    return CriterionCheckSummary.notAutomated;
  }

  /// Evaluates only the explicitly authored named-test contract at a saved run.
  /// This never verifies prose semantics or live artifact freshness.
  bool criterionVerifiedAgainstChecks(
    ProjectRequirement requirement,
    AcceptanceCriterionDefinition criterion,
  ) =>
      criterion.verificationRule ==
          CriterionVerificationRule.allMappedNamedTests &&
      criterion.checkIds.isNotEmpty &&
      criterion.checkIds.toSet().length == criterion.checkIds.length &&
      criterion.checkIds.every(
        (id) => requirement.checks.any(
          (c) =>
              c.id == id &&
              c.type == AcceptanceCheckType.automated &&
              c.target != null,
        ),
      ) &&
      criterionCheckSummary(requirement, criterion) ==
          CriterionCheckSummary.automatedChecksPassed;

  String criterionVerdictLabel(
    ProjectRequirement requirement,
    AcceptanceCriterionDefinition criterion,
  ) => criterionVerifiedAgainstChecks(requirement, criterion)
      ? 'Criterion rule: verified against authored named tests at saved revision'
      : 'Criterion acceptance: not verified';

  /// Deterministic authored-rule verdict; no free-form coverage is inferred.
  Map<String, Object?> criterionEvidence(
    ProjectRequirement requirement,
    AcceptanceCriterionDefinition criterion,
  ) => {
    ...criterion.toJson(),
    'status': criterionVerifiedAgainstChecks(requirement, criterion)
        ? 'verifiedAgainstAuthoredChecks'
        : 'unverified',
    'requirementSha256': RequirementAcceptanceEvidence(requirement)
        .requirementSha256,
    'savedRunSha256': revisionIdentity?.savedRunSha256,
    'mappingStatus': criterion.checkIds.isEmpty ? 'unmapped' : 'authored',
    'checkSummary': criterionCheckSummary(requirement, criterion).name,
    'scope': 'Only an explicitly selected named-test rule can verify its authored check contract at this saved revision. Prose semantics, the free-form acceptance block and current files remain unverified.',
    'checks': [
      for (final id in criterion.checkIds)
        directCheck(
          requirement,
          requirement.checks.firstWhere((c) => c.id == id),
        ).toJson(),
    ],
  };

  final List<ManualCheckObservation> manualObservations;
  ManualCheckObservation? observationFor(
    String requirementId,
    String checkId,
  ) => manualObservations
      .where((v) => v.requirementId == requirementId && v.checkId == checkId)
      .firstOrNull;
  bool get canRecordManualObservation =>
      savedInputsCurrent &&
      revisionIdentity?.savedRunSha256 != null &&
      savedProject?.phase == SourceGenerationPhase.ready &&
      savedProject!.pendingOperation.isEmpty &&
      savedProject!.failedOperation.isEmpty &&
      savedProject!.steps.isNotEmpty &&
      savedProject!.steps.every((s) => s.succeeded);
  bool observationCurrent(ManualCheckObservation value) =>
      canRecordManualObservation &&
      value.runSha256 == revisionIdentity?.savedRunSha256 &&
      results.any(
        (r) =>
            r.requirement.id == value.requirementId &&
            r.acceptance.requirementSha256 == value.requirementSha256 &&
            r.requirement.checks.any(
              (c) =>
                  c.id == value.checkId && c.type == AcceptanceCheckType.manual,
            ),
      );
  final int requirementsRevision;
  final List<RequirementCheckResult> results;
  final String evidenceJson;
  final GeneratedProject? savedProject;
  final String snapshotFingerprint;
  final RequirementRunIdentity? revisionIdentity;
  final bool savedInputsCurrent;

  String get revisionContext => revisionIdentity?.savedRunSha256 == null
      ? 'Saved run identity unavailable. Missing source, input or approval evidence.'
      : savedInputsCurrent
      ? 'Saved inputs and approval match current project records.'
      : 'Saved inputs or approval are stale relative to current project records.';

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
      'task status is progress only; prose acceptance remains unverified. Explicit named-test rules verify only their saved check contract.';

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
      'No automated acceptance verdict is recorded for this acceptance block. '
      'Manual observations are self-reported. Generic operation results, manual '
      'task progress and advisory model Review do not verify acceptance.';
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

/// Public bounded evidence attached to one authored declaration. A saved pass
/// proves the selected check outcome only, never coverage of the whole block.
class RequirementDirectCheckEvidence {
  RequirementDirectCheckEvidence(
    this.check,
    this.status,
    Map<String, Object>? result,
  ) : result = result == null ? null : Map.unmodifiable(result);
  final AcceptanceCheckDefinition check;
  final String status;
  final Map<String, Object>? result;
  String get label => switch (status) {
    'savedTargetPassed' => 'Automated check: saved target passed',
    'savedTargetNotPassed' => 'Automated check: saved target did not pass',
    'manuallyReportedPassed' => 'Manual check: self-reported pass',
    'manuallyReportedFailed' => 'Manual check: self-reported failure',
    'stale' => 'Direct check: stale evidence',
    'advisoryOnly' => 'Advisory check: no acceptance verdict',
    _ => 'Direct check: missing evidence',
  };
  Map<String, Object?> toJson() => {
    ...check.toJson(),
    'status': status,
    'result': result,
    'scope': 'Saved declaration-specific evidence only; acceptance remains unverified. Manual results are self-reported and advisory checks supply no verdict.',
  };
}

/// Aggregate observation states only. Even all mapped tests passing leaves the
/// authored criterion's semantic coverage and acceptance unverified.
enum CriterionCheckSummary {
  unmapped,
  missing,
  stale,
  failed,
  notAutomated,
  automatedChecksPassed;

  String get label => switch (this) {
    unmapped => 'Criterion checks: no mappings',
    missing => 'Criterion checks: missing evidence',
    stale => 'Criterion checks: stale evidence',
    failed => 'Criterion checks: recorded failure',
    notAutomated =>
      'Criterion checks: manual or advisory evidence only or mixed',
    automatedChecksPassed =>
      'Criterion checks: all mapped automated checks passed',
  };
}
