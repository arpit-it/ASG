// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'agent_session_publication.dart';
import 'requirement_check_report.dart';
import 'requirements_board.dart';

/// Display facts only. No aggregate task-completion or execution decision.
final class PublishedTaskCheck {
  PublishedTaskCheck(this.id, this.expectation, this.label, List<String> facts)
    : facts = List.unmodifiable(facts);
  final String id, expectation, label;
  final List<String> facts;
}

final class PublishedTaskCriterion {
  PublishedTaskCriterion({
    required this.id,
    required this.text,
    required this.rule,
    required this.summary,
    required this.verdict,
    required List<String> checkIds,
  }) : checkIds = List.unmodifiable(checkIds);
  final String id, text, rule, summary, verdict;
  final List<String> checkIds;
}

/// An already validated publication-to-report projection. Storage/currentness
/// checks belong to the read-only service; this value owns immutable display data.
final class PublishedTaskEvidence {
  PublishedTaskEvidence._({
    required this.sessionId,
    required this.runNumber,
    required this.taskId,
    required this.requirementId,
    required this.title,
    required this.acceptance,
    required this.withdrawn,
    required List<PublishedTaskCheck> checks,
    required List<PublishedTaskCriterion> criteria,
  }) : checks = List.unmodifiable(checks),
       criteria = List.unmodifiable(criteria);
  final String sessionId, taskId, requirementId, title, acceptance;
  final int runNumber;
  final bool withdrawn;
  final List<PublishedTaskCheck> checks;
  final List<PublishedTaskCriterion> criteria;

  factory PublishedTaskEvidence.fromReport({
    required AgentSessionPublication publication,
    required ProjectRequirement requirement,
    required RequirementCheckReport report,
    required bool withdrawn,
  }) {
    final task = publication.session.tasks.items.singleWhere(
      (task) => task.id == publication.reference.boardTaskId,
    );
    if (task.requirementId != requirement.id ||
        !report.results.any(
          (result) => identical(result.requirement, requirement),
        )) {
      throw const FormatException('Published task requirement does not match.');
    }
    return PublishedTaskEvidence._(
      sessionId: publication.session.sessionId,
      runNumber: publication.runNumber,
      taskId: task.id,
      requirementId: requirement.id,
      title: requirement.title,
      acceptance: requirement.acceptance,
      withdrawn: withdrawn,
      checks: [
        for (final check in requirement.checks)
          () {
            final direct = report.directCheck(requirement, check);
            final facts = <String>[];
            final target = check.target;
            if (target != null) {
              facts.add('Authored target: ${target.file} — ${target.name}');
            }
            final named = report.namedObservationFor(requirement.id, check.id);
            final manual = report.observationFor(requirement.id, check.id);
            if (check.type == AcceptanceCheckType.automated && named != null) {
              final result = named.result;
              facts.addAll([
                'Recorded target: ${result.target.file} — ${result.target.name}',
                'Recorded named target: ${result.passed ? 'passed' : 'not passed'}',
                'Recorded exit: ${result.exitCode}',
                'Cancelled: ${result.cancelled}; timed out: ${result.timedOut}; output limit reached: ${result.outputLimitExceeded}',
                'Observed at ${named.observedAt.toUtc().toIso8601String()}',
              ]);
            } else if (check.type == AcceptanceCheckType.manual &&
                manual != null) {
              facts.add(
                'Self-reported ${manual.passed ? 'pass' : 'failure'} at ${manual.observedAt.toUtc().toIso8601String()}',
              );
            }
            return PublishedTaskCheck(
              check.id,
              check.expectation,
              direct.label,
              facts,
            );
          }(),
      ],
      criteria: [
        for (final criterion in requirement.criteria)
          PublishedTaskCriterion(
            id: criterion.id,
            text: criterion.text,
            rule:
                criterion.verificationRule ==
                    CriterionVerificationRule.allMappedNamedTests
                ? 'Authored rule: all mapped named tests'
                : 'No verification rule authored',
            summary: report.criterionCheckSummary(requirement, criterion).label,
            verdict: report.criterionVerdictLabel(requirement, criterion),
            checkIds: criterion.checkIds,
          ),
      ],
    );
  }
}
