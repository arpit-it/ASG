// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/generation_capabilities.dart';

class GenerationCapabilityPanel extends StatelessWidget {
  const GenerationCapabilityPanel({super.key, required this.report});
  final GenerationCapabilities report;

  @override
  Widget build(BuildContext context) => ExpansionTile(
    title: const Text('Generation host capabilities'),
    subtitle: Text(report.host),
    childrenPadding: const EdgeInsets.all(12),
    expandedCrossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text(GenerationCapabilities.limits),
      for (final operation in report.operations) ...[
        const SizedBox(height: 12),
        Text(
          '${operation.name}: ${operation.implemented ? 'Implemented path' : 'Unavailable / unverified'}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        Text(operation.detail),
      ],
    ],
  );
}
