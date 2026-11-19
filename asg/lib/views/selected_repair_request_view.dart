// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/repair_attempt.dart';
import '../models/selected_repair_request.dart';

/// Historical observations only. Reload cannot restore or replay a request.
class SelectedRepairRequestView extends StatelessWidget {
  const SelectedRepairRequestView({
    super.key,
    required this.sessionId,
    required this.history,
    required this.error,
    required this.onReload,
  });
  final String? sessionId;
  final SelectedRepairHistory? history;
  final String? error;
  final VoidCallback onReload;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(),
      Text(
        'Saved selected repair requests',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (sessionId == null)
        const Text('Select a saved session to review request provenance.')
      else ...[
        Text('Session $sessionId'),
        const Text(
          'Historical observations only. Proposed does not mean accepted '
          'or repaired. Reload starts no request or tool and restores no source.',
        ),
        if (error != null) Text(error!),
        TextButton(
          onPressed: onReload,
          child: const Text('Reload repair history'),
        ),
        if (history != null && history!.omittedProjectAttempts > 0)
          Text(
            '${history!.omittedProjectAttempts} older project attempts omitted '
            'from this view. Saved history and budgets are unchanged.',
          ),
        if (history != null && history!.entries.isEmpty)
          const Text(
            'No matching selected repair provenance in the visible project history.',
          ),
        for (final entry in history?.entries ?? <SelectedRepairHistoryEntry>[])
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Attempt ${entry.attempt.number} · ${entry.attempt.status.name}',
                ),
                if (entry.attempt.status == RepairAttemptStatus.reserved)
                  const Text(
                    'Outcome unresolved. Saved intent does not prove transport started or stopped.',
                  ),
                if (entry.origin == null)
                  const Text(
                    'Selected request provenance unavailable. Legacy or unreadable metadata cannot identify this session’s request intent.',
                  )
                else ...[
                  Text(
                    'Requested task ${entry.origin!.boardTaskId} · '
                    'Requirement ${entry.origin!.requirementId} · '
                    'Board revision ${entry.origin!.requirementsRevision}',
                  ),
                  Text(
                    entry.attempt.modelRequest?.description ??
                        'Model provenance unavailable.',
                  ),
                  for (final source in entry.origin!.sourceSha256.entries)
                    SelectableText('${source.key}\nSHA256 ${source.value}'),
                  if (entry.reference != null)
                    const Text(
                      'Proposed outcome matches the retained request origin and attempt. This grants no acceptance or execution authority.',
                    ),
                ],
              ],
            ),
          ),
      ],
    ],
  );
}
