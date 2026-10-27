// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/repair_attempt.dart';
import 'source_diff_view.dart';

/// Read-only evidence; a produced proposal never establishes repaired checks.
class RepairHistoryView extends StatelessWidget {
  const RepairHistoryView({
    super.key,
    required this.attempts,
    required this.error,
    required this.usage,
    required this.usesCurrentApproval,
  });

  final List<RepairAttempt> attempts;
  final String? error;
  final Map<String, int> usage;
  final bool Function(RepairAttempt) usesCurrentApproval;

  String _outcome(RepairAttempt attempt) => switch (attempt.status) {
    RepairAttemptStatus.reserved => 'Outcome not recorded; request may be active or interrupted. Budget consumed.',
    RepairAttemptStatus.proposed =>
      'Proposal saved, unverified. Checks must be rerun before repair success.',
    RepairAttemptStatus.failed => 'Model request failed. Budget consumed.',
    RepairAttemptStatus.cancelled => 'Model request cancelled. Budget consumed; server inference may continue.',
  };

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(),
      Text(
        'Saved repair attempts',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (error != null)
        Text(error!)
      else ...[
        const Text(
          'Current approval usage (maximum 3 requests per category). '
          'Failed, cancelled and unfinished requests count. Previous approvals '
          'remain in history. Without a current approval, usage is zero.',
        ),
        for (final entry in usage.entries)
          Text('${entry.key}: ${entry.value}/3 requests used'),
        if (attempts.isEmpty) const Text('No saved repair requests.'),
        for (final attempt in attempts.reversed)
          ExpansionTile(
            key: ValueKey('repair-attempt-${attempt.number}'),
            title: Text(
              'Repair request ${attempt.number} · ${attempt.category}',
            ),
            subtitle: Text(_outcome(attempt)),
            childrenPadding: const EdgeInsets.all(12),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Started ${attempt.startedAt.toUtc().toIso8601String()}'),
              Text(
                usesCurrentApproval(attempt)
                    ? 'Current approval'
                    : 'Previous or no longer current approval',
              ),
              Text(
                'Approved ${attempt.failure.snapshot.approval!.recordedAt.toUtc().toIso8601String()}',
              ),
              Text('Original failed check run ${attempt.failure.number}'),
              SelectableText(attempt.failure.snapshot.directory),
              Text(
                'Original ${attempt.category} exit ${attempt.failure.snapshot.steps.last.exitCode}',
              ),
              SelectableText(attempt.failure.snapshot.steps.last.output),
              if (attempt.proposal != null) ...[
                SelectableText(attempt.proposal!.summary),
                for (final change in attempt.proposal!.changes) ...[
                  SelectableText(change.path),
                  SourceDiffView(diff: change.diff),
                ],
              ],
            ],
          ),
      ],
    ],
  );
}
