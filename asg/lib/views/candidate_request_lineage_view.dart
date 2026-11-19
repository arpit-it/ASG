// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/candidate_request_lineage.dart';

/// A detached historical relationship, with no recovery or execution controls.
class CandidateRequestLineageView extends StatelessWidget {
  const CandidateRequestLineageView({super.key, required this.review});
  final CandidateRequestLineageReview? review;

  @override
  Widget build(BuildContext context) {
    final value = review;
    if (value == null) {
      return const Text(
        'Initial request lineage is unavailable. Legacy, unbound and repair candidates do not acquire an inferred request link.',
      );
    }
    final request = value.request;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Initial request ${request.number} → candidate run ${value.lineage.runNumber}',
          style: Theme.of(context).textTheme.titleSmall,
        ),
        Text(
          'Session ${request.sessionId} · task ${request.boardTaskId} · requirement ${request.requirementId}',
        ),
        Text(
          'Requested model: ${request.modelRequest.model}. Response model: ${request.modelRequest.responseModel}.',
        ),
        Text('Captured input: ${request.sourceSha256.keys.join(', ')}'),
        Text('Returned changes: ${request.returnedSha256.keys.join(', ')}'),
        const Text(
          'Recorded preparation relationship only. This does not confirm acceptance, command execution, requirement completion or model authenticity. No source is restored or request replayed.',
        ),
      ],
    );
  }
}
