// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/prerequisite_preparation_evidence.dart';

import '../controllers/published_task_evidence_controller.dart';

class PublishedTaskEvidenceScreen extends StatefulWidget {
  const PublishedTaskEvidenceScreen({super.key, required this.controller});
  final PublishedTaskEvidenceController controller;
  @override
  State<PublishedTaskEvidenceScreen> createState() =>
      _PublishedTaskEvidenceScreenState();
}

class _PublishedTaskEvidenceScreenState
    extends State<PublishedTaskEvidenceScreen> {
  PublishedTaskEvidenceController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
    controller.load();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('Published task evidence'),
      actions: [
        IconButton(
          tooltip: 'Reload saved evidence',
          onPressed: controller.busy ? null : controller.load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Saved records only. Opening or reloading runs no checks, model, file inspection or writes.',
        ),
        const Text(
          'Saved check facts do not establish live files, prose coverage, task completion or dependency readiness.',
        ),
        if (controller.decision case final decision?) ...[
          const Text('Retained authored-check completion decision'),
          Text(
            'Session ${decision.evidence.publication.session.sessionId} · run ${decision.evidence.publication.runNumber} · task ${decision.evidence.publication.reference.boardTaskId}',
          ),
          Text(
            'Confirmed at ${decision.confirmedAt.toUtc().toIso8601String()}',
          ),
          const Text(
            'Completed against all authored named-test contracts at the saved revision. Historical decision only: prose, live files, current compatibility and dependent execution remain unverified. Board status is unchanged.',
          ),
          Text(
            '${decision.evidence.requirement.id}: ${decision.evidence.requirement.title}',
          ),
          for (final criterion in decision.evidence.requirement.criteria)
            Text(
              '${criterion.id}: ${criterion.text} — saved authored named-test rule passed',
            ),
          for (final observation in decision.evidence.observations)
            Text(
              'Saved check ${observation.checkId}: ${observation.result.target.file} — ${observation.result.target.name}; named target passed at ${observation.observedAt.toUtc().toIso8601String()}',
            ),
          for (final prerequisite in decision.evidence.prerequisites)
            Text(
              'Selected historical prerequisite ${prerequisite.taskId}: run ${prerequisite.runNumber}',
            ),
        ],
        if (controller.decision != null) ...[
          const Text('Recorded preparation provenance'),
          const Text(
            'Exact saved preparation facts only. These do not prove current files, behavior, dependency readiness or permission to execute.',
          ),
          if (controller.preparationReview case final review?) ...[
            if (review.prerequisites.isEmpty)
              const Text(
                'This retained decision has no historical prerequisites.',
              ),
            for (final edge in review.prerequisites)
              Text(
                'Prerequisite ${edge.reference.taskId}, run ${edge.reference.runNumber}: ${switch (edge.state) {
                  PrerequisitePreparationState.directRecordedLink => 'Recorded working base and reviewed source map match this prerequisite publication.',
                  PrerequisitePreparationState.noDirectMatch => 'No direct recorded preparation match. This does not establish whether earlier behavior was retained.',
                  PrerequisitePreparationState.unavailable => 'Preparation proof is unavailable. Existing historical decision is retained.',
                }}',
              ),
          ],
          if (controller.preparationError case final error?) Text(error),
        ],
        if (controller.decisionError case final error?) Text(error),
        if (controller.evidence != null &&
            controller.decision == null &&
            !controller.selectedSession.cancellationRequested) ...[
          const Text('Optional explicit decision against authored checks'),
          const Text(
            'This saves a historical decision only. It does not change board status, verify prose or current files, or authorize dependent execution. Prerequisite decisions describe their saved contracts, not current artifact compatibility.',
          ),
          for (final entry in controller.prerequisiteOptions.entries) ...[
            Text('Select retained prerequisite decision for ${entry.key}'),
            if (entry.value.isEmpty)
              const Text('No applicable retained decision is available.'),
            DropdownButton<int>(
              isExpanded: true,
              hint: const Text('Choose an exact saved run'),
              value: controller.prerequisiteSelection(entry.key),
              items: [
                for (final number in entry.value)
                  DropdownMenuItem(
                    value: number,
                    child: Text('Published run $number'),
                  ),
              ],
              onChanged: controller.busy
                  ? null
                  : (value) => controller.choosePrerequisite(entry.key, value),
            ),
          ],
          if (controller.canConsent)
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              value: controller.consent,
              title: const Text(
                'I confirm completion only against all authored named-test contracts and the selected historical prerequisites.',
              ),
              onChanged: (value) => controller.setConsent(value ?? false),
            ),
          OutlinedButton(
            onPressed: controller.canConfirm ? controller.confirm : null,
            child: const Text('Record authored-check completion decision'),
          ),
          if (controller.busy)
            OutlinedButton(
              onPressed: controller.cancelConfirmation,
              child: const Text('Withdraw pending confirmation'),
            ),
        ],
        if (controller.error case final error?) ...[
          Text(error),
          OutlinedButton(
            onPressed: controller.busy ? null : controller.load,
            child: const Text('Retry saved evidence review'),
          ),
        ],
        if (controller.evidence case final evidence?) ...[
          Text(
            'Session ${evidence.sessionId} · published run ${evidence.runNumber} · task ${evidence.taskId}',
          ),
          if (evidence.withdrawn)
            const Text(
              'Session cancellation was requested. These are read-only saved facts.',
            ),
          Text(
            '${evidence.requirementId}: ${evidence.title}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const Text('Acceptance text — not verified by this review'),
          Text(evidence.acceptance),
          if (evidence.criteria.isEmpty)
            const Text('No authored criteria. Acceptance remains unverified.'),
          for (final criterion in evidence.criteria)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${criterion.id}: ${criterion.text}',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text(criterion.rule),
                  Text(criterion.summary),
                  Text(criterion.verdict),
                  Text(
                    criterion.checkIds.isEmpty
                        ? 'No checks mapped.'
                        : 'Mapped checks: ${criterion.checkIds.join(', ')}',
                  ),
                ],
              ),
            ),
          const Text('Authored check facts'),
          if (evidence.checks.isEmpty)
            const Text(
              'No authored checks. Generic operation success is not a direct check result.',
            ),
          for (final check in evidence.checks)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${check.id}: ${check.expectation}'),
                  Text(check.label),
                  for (final fact in check.facts) Text(fact),
                ],
              ),
            ),
        ],
      ],
    ),
  );
}
