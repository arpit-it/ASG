// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/session_proposal_request.dart';

/// Read-only request observations; this view has no retry/replay execution action.
class SourceRequestHistory extends StatelessWidget {
  const SourceRequestHistory({
    super.key,
    required this.sessionId,
    required this.requests,
    required this.error,
    required this.onReload,
  });
  final String? sessionId;
  final List<SessionProposalRequest> requests;
  final String? error;
  final VoidCallback onReload;

  String _outcome(SessionProposalRequest value) => switch (value.status) {
    SessionProposalRequestStatus.reserved => 'Outcome unresolved. Saved intent does not prove transport started or stopped.',
    SessionProposalRequestStatus.returnedValidated => 'Validated proposal returned at that time. Source was not accepted or executed.',
    SessionProposalRequestStatus.failedLocally =>
      'Request failed locally. Remote completion or stop is unconfirmed.',
    SessionProposalRequestStatus.cancelledLocally =>
      'Request cancelled locally. Remote completion or stop is unconfirmed.',
  };

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Divider(),
      Text(
        'Saved initial source requests',
        style: Theme.of(context).textTheme.titleMedium,
      ),
      if (sessionId == null)
        const Text(
          'Select a saved session to retain initial request history. Unbound source requests are not journaled; repair history is separate.',
        )
      else ...[
        Text(
          'Session $sessionId · historical observations only. Reopening and reloading start no work. '
          'Source replacements are not retained here. A fresh explicit request and current approval are required for a new proposal.',
        ),
        TextButton(
          onPressed: onReload,
          child: const Text('Reload request history'),
        ),
        if (error != null) Text(error!),
        if (error != null && requests.isNotEmpty)
          const Text(
            'Last observed request history; current saved history is unavailable.',
          ),
        if (error == null && requests.isEmpty)
          const Text('No saved initial source requests.'),
        for (final value in requests.reversed)
          ExpansionTile(
            key: ValueKey('initial-request-${value.number}'),
            title: Text(
              'Initial request ${value.number} · ${value.boardTaskId}',
            ),
            subtitle: Text(_outcome(value)),
            childrenPadding: const EdgeInsets.all(12),
            expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Requirement ${value.requirementId} · revision ${value.requirementsRevision}',
              ),
              Text('Started ${value.startedAt.toIso8601String()}'),
              if (value.finishedAt != null)
                Text(
                  'Local outcome recorded ${value.finishedAt!.toIso8601String()}',
                ),
              Text(value.modelRequest.description),
              SelectableText(
                'Recorded session fingerprint: ${value.sessionSha256}',
              ),
              SelectableText('Approval fingerprint: ${value.approvalSha256}'),
              SelectableText(
                'Recorded working fingerprint: ${value.workingSha256}',
              ),
              for (final e in value.sourceSha256.entries) ...[
                SelectableText(e.key),
                SelectableText('Requested source fingerprint: ${e.value}'),
                if (value.returnedSha256.containsKey(e.key))
                  SelectableText(
                    'Returned replacement fingerprint: ${value.returnedSha256[e.key]}',
                  ),
              ],
              const Text(
                'Fingerprints describe recorded snapshots, not current files, compatible dependencies, accepted changes or execution permission.',
              ),
            ],
          ),
      ],
    ],
  );
}
