// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/source_generation.dart';

class BoardVerificationProgress extends StatelessWidget {
  const BoardVerificationProgress({
    super.key,
    required this.result,
    required this.active,
  });
  final GeneratedProject result;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final summaries = result.boardVerification(active: active);
    if (summaries.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Linked board task verification'),
        const Text(
          'Only mapped starter operations are summarized. These results do not '
          'mark board tasks complete or verify requirement acceptance.',
        ),
        for (final summary in summaries)
          ListTile(
            title: Text('${summary.boardTaskId}: ${summary.status.name}'),
            subtitle: Text(
              '${summary.passed}/${summary.total} mapped operations passed',
            ),
          ),
      ],
    );
  }
}
