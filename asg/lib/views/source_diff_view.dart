// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/source_line_diff.dart';

class SourceDiffView extends StatelessWidget {
  const SourceDiffView({super.key, required this.diff});

  final SourceLineDiff diff;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Line changes'),
      const Text(
        '− removed, + added, space unchanged. Columns: original / replacement line. '
        'Line endings appear in brackets; no newline means the file ends there.',
      ),
      if (diff.coarse)
        const Text(
          'Large comparison: the changed region is shown as a complete removal '
          'and addition. Unchanged lines inside that region may appear twice.',
        ),
      SelectableText(
        diff.display,
        style: Theme.of(context).textTheme.bodyMedium
            ?.copyWith(fontFamily: 'monospace'),
      ),
      const SizedBox(height: 12),
    ],
  );
}
