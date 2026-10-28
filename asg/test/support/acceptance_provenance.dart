// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/requirement_check_report.dart';

/// Test-only, digest-only linkage to F10. This is not a scenario verdict or a
/// collector record: host/model/configuration identity must be added separately.
Map<String, Object> acceptanceProvenance(
  RequirementCheckReport report, {
  required String scenario,
  required String sourceRevision,
}) {
  const scenarios = {'reviewed-candidate', 'bounded-repair'};
  final revision = RegExp(r'^[a-f0-9]{40}$');
  final digest = RegExp(r'^[a-f0-9]{64}$');
  final identity = report.revisionIdentity;
  final evidence = jsonDecode(report.evidenceJson) as Map<String, dynamic>;
  final requirement = evidence['requirementsBoardSha256'];
  final source = identity?.sourceSha256;
  final input = identity?.savedInputSha256;
  final approval = identity?.approvalSha256;
  final run = identity?.savedRunSha256;
  if (!scenarios.contains(scenario) ||
      !revision.hasMatch(sourceRevision) ||
      report.requirementsRevision < 1 ||
      !report.savedInputsCurrent ||
      identity?.currentInputSha256 != input ||
      [
        requirement,
        source,
        input,
        approval,
        run,
      ].any((value) => value is! String || !digest.hasMatch(value))) {
    throw const FormatException('Complete current F10 provenance is required.');
  }
  return {
    'schemaVersion': 1,
    'scope': 'f10-saved-snapshot-link-only',
    'scenarioId': scenario,
    'sourceRevision': sourceRevision,
    'requirementSha256': requirement as String,
    'inputSha256': input!,
    'generatedSourceSha256': source!,
    'approvalSha256': approval!,
    'savedRunSha256': run!,
  };
}

/// Disabled by default. The caller invokes this only after successful durable
/// reopen assertions. Captured test logs are private; share only this JSON line.
String? acceptanceProvenanceLine(
  RequirementCheckReport report, {
  required String scenario,
  bool enabled = const bool.fromEnvironment('ASG_ACCEPTANCE_PROVENANCE'),
  String sourceRevision = const String.fromEnvironment('ASG_TESTED_REVISION'),
}) => !enabled
    ? null
    : 'ASG_F10_PROVENANCE=${jsonEncode(acceptanceProvenance(report, scenario: scenario, sourceRevision: sourceRevision))}';
