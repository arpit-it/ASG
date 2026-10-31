// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/runtime_capabilities.dart';
import '../models/runtime_setup.dart';

class RuntimeCapabilityPanel extends StatelessWidget {
  const RuntimeCapabilityPanel({
    super.key,
    required this.report,
    required this.selected,
    required this.backend,
  });
  final RuntimeCapabilities? report;
  final ModelCandidate? selected;
  final RuntimeBackend backend;

  @override
  Widget build(BuildContext context) {
    final current = report;
    if (current == null) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text(
          'Capabilities not inspected for this selection. Inspect uses the chosen Python without loading weights, probing devices or installing packages.',
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Detected host: ${current.host}'),
          for (final item in current.backends) ...[
            const SizedBox(height: 8),
            Text('${item.backend.label}: ${item.availability}'),
            Text(item.modelCompatibility(selected)),
          ],
          const SizedBox(height: 8),
          Text(
            backend == RuntimeBackend.auto
                ? 'Auto would prefer ${current.preferred.backend.label} by dependency presence only; launch revalidates. No fallback retry.'
                : 'Selected: ${backend.label}. No fallback retry.',
          ),
          const Text(
            'CPU/CUDA unavailable. No memory adequacy check or successful inference is implied. Launch validates the actual device and model load.',
          ),
        ],
      ),
    );
  }
}
