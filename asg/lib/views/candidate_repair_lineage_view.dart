// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/candidate_repair_lineage.dart';

/// Exact historical observations only; no recovery or execution controls.
class CandidateRepairLineageView extends StatelessWidget {
  const CandidateRepairLineageView({super.key, required this.review});
  final CandidateRepairLineageReview? review;
  @override
  Widget build(BuildContext context) {
    final value = review;
    if (value == null) {
      return const Text(
        'Repair request lineage is unavailable. Missing, legacy, '
        'unbound or inconsistent proof does not acquire an inferred repair link.',
      );
    }
    final origin = value.origin;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Repair request ${origin.attemptNumber} → candidate run ${value.lineage.runNumber}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        Text(
          'Session ${origin.requestSession.sessionId} · task ${origin.boardTaskId} · '
          'requirement ${origin.requirementId}',
        ),
        Text(
          'Original failed run ${value.attempt.failure.number} · '
          '${value.attempt.category} · board revision ${origin.requirementsRevision}',
        ),
        Text(value.attempt.modelRequestDescription),
        for (final entry in origin.sourceSha256.entries)
          SelectableText('Selected input ${entry.key}\nSHA256 ${entry.value}'),
        Text('Recorded dispatch ${value.lineage.dispatchId}'),
        const Text(
          'Recorded repair preparation relationship only. A proposed repair '
          'is not accepted or verified; startup is not a command receipt or task '
          'completion. This does not authenticate a model. Reload restores no source, '
          'replays no request and starts no tool.',
        ),
      ],
    );
  }
}
