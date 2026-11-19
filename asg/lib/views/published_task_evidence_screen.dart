// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

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
          onPressed: controller.load,
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
        if (controller.error case final error?) ...[
          Text(error),
          OutlinedButton(
            onPressed: controller.load,
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
