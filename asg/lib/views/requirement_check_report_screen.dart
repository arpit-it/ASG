// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/requirement_check_report_controller.dart';
import '../models/requirement_check_report.dart';
import '../models/requirements_board.dart';

class RequirementCheckReportScreen extends StatefulWidget {
  const RequirementCheckReportScreen({super.key, required this.controller});
  final RequirementCheckReportController controller;
  @override
  State<RequirementCheckReportScreen> createState() =>
      _RequirementCheckReportScreenState();
}

class _RequirementCheckReportScreenState
    extends State<RequirementCheckReportScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.load();
  }

  @override
  void dispose() {
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final report = widget.controller.report;
      return Scaffold(
        appBar: AppBar(title: const Text('Requirement check report')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(RequirementCheckReport.limits),
            TextButton(
              onPressed: widget.controller.saving
                  ? null
                  : widget.controller.load,
              child: const Text('Reload saved evidence'),
            ),
            TextButton(
              onPressed:
                  widget.controller.inspecting ||
                      widget.controller.saving ||
                      report?.savedProject == null
                  ? null
                  : widget.controller.inspectArtifacts,
              child: Text(
                widget.controller.inspecting
                    ? 'Inspecting current artifacts…'
                    : 'Inspect current artifacts',
              ),
            ),
            if (widget.controller.inspecting) const LinearProgressIndicator(),
            if (widget.controller.inspection != null)
              Text(widget.controller.inspection!.label),
            if (widget.controller.inspectedAt != null)
              Text(
                'Observed at ${widget.controller.inspectedAt!.toIso8601String()} (UTC); files may change afterward.',
              ),
            if (widget.controller.inspectionNotice != null)
              Text(widget.controller.inspectionNotice!),
            if (widget.controller.error != null)
              SelectableText(widget.controller.error!),
            if (report != null) ...[
              Text('Requirements revision ${report.requirementsRevision}'),
              _RevisionContext(report: report),
              if (report.results.isEmpty)
                const Text('No structured requirements recorded.'),
              for (final result in report.results)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${result.requirement.id}: ${result.requirement.title}',
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                        const Text(RequirementCheckResult.acceptanceStatus),
                        Text(result.requirement.acceptance),
                        const Text(RequirementAcceptanceEvidence.label),
                        const Text(RequirementAcceptanceEvidence.reason),
                        Text(
                          'Requirement SHA-256: ${result.acceptance.requirementSha256}',
                        ),
                        for (final check in result.requirement.checks) ...[
                          Text(
                            'Declared check ${check.id} (${check.type.name})',
                          ),
                          Text(check.expectation),
                          if (check.target case final target?)
                            Text(
                              'Declared Flutter test: ${target.file}; exact name: ${target.name}.',
                            ),
                          if ((check.type == AcceptanceCheckType.automated
                                  ? report.namedObservationFor(
                                      result.requirement.id,
                                      check.id,
                                    )
                                  : null)
                              case final observation?) ...[
                            Text(
                              '${report.namedObservationCurrent(observation) ? "Saved" : "Stale saved"} named-test result: ${observation.result.passed ? "passed" : "not passed"}',
                            ),
                            Text(
                              'Executed target: ${observation.result.target.file}; exact name: ${observation.result.target.name}',
                            ),
                            Text(
                              'Observed at ${observation.observedAt.toUtc().toIso8601String()} (UTC)',
                            ),
                            SelectableText(
                              'Saved run SHA-256: ${observation.runSha256}',
                            ),
                            const Text(
                              'Saved command evidence only; current files and acceptance criteria remain unverified.',
                            ),
                          ] else if (report.observationFor(
                                result.requirement.id,
                                check.id,
                              )
                              case final observation?) ...[
                            Text(
                              report.observationCurrent(observation)
                                  ? 'Manual observation: ${observation.passed ? "passed" : "failed"}'
                                  : 'Stale manual observation: ${observation.passed ? "passed" : "failed"}',
                            ),
                            Text(
                              'Observed at ${observation.observedAt.toUtc().toIso8601String()}',
                            ),
                          ] else
                            const Text(
                              'Missing direct result; acceptance remains unverified.',
                            ),
                          if (check.type == AcceptanceCheckType.manual) ...[
                            const Text(
                              'Record only what you personally checked against this saved revision. This does not run a check or verify acceptance. Manual observations stay on this device and are excluded from portable backups.',
                            ),
                            Wrap(
                              spacing: 8,
                              children: [
                                for (final passed in [true, false])
                                  TextButton(
                                    onPressed:
                                        widget.controller.saving ||
                                            widget.controller.inspecting ||
                                            !report.canRecordManualObservation
                                        ? null
                                        : () => widget.controller
                                              .recordManualObservation(
                                                result.requirement.id,
                                                check.id,
                                                passed,
                                              ),
                                    child: Text(
                                      'Record manual ${passed ? "pass" : "fail"} for ${check.id}',
                                    ),
                                  ),
                              ],
                            ),
                          ],
                        ],
                        Text(result.label),
                        Text(result.reason),
                        for (final check in result.checks)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${check.taskId} (${check.boardTaskId}): ${check.operation.name} — ${check.status.name}',
                                ),
                                Text(check.summary),
                              ],
                            ),
                          ),
                        Text(
                          'Tasks: ${result.taskIds.isEmpty ? 'none' : result.taskIds.join(', ')}',
                        ),
                        Text(
                          'Operations: ${result.operationIds.isEmpty ? 'none' : result.operationIds.join(', ')}',
                        ),
                      ],
                    ),
                  ),
                ),
              ExpansionTile(
                title: const Text('Exact saved revision and results'),
                children: [
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: Text(RequirementCheckReport.authoredEvidenceNotice),
                  ),
                  Padding(
                    padding: const EdgeInsets.all(12),
                    child: SelectableText(widget.controller.evidenceJson!),
                  ),
                ],
              ),
            ],
          ],
        ),
      );
    },
  );
}

/// Read-only context from the same typed projection used by copied evidence.
class _RevisionContext extends StatelessWidget {
  const _RevisionContext({required this.report});
  final RequirementCheckReport report;

  @override
  Widget build(BuildContext context) {
    final identity = report.revisionIdentity;
    final hashes = <String, String?>{
      'Saved run SHA-256': identity?.savedRunSha256,
      'Saved source SHA-256': identity?.sourceSha256,
      'Saved input SHA-256': identity?.savedInputSha256,
      'Saved approval SHA-256': identity?.approvalSha256,
      'Current input SHA-256': identity?.currentInputSha256,
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Revision context',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(report.revisionContext),
            const Text(
              'Content identity only. This does not verify acceptance or current files on disk. Use artifact inspection for a point-in-time file comparison.',
            ),
            for (final entry in hashes.entries) ...[
              Text(entry.key),
              SelectionArea(child: Text(entry.value ?? 'Unavailable')),
            ],
          ],
        ),
      ),
    );
  }
}
