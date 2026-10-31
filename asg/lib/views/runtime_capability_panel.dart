// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/runtime_capabilities.dart';
import '../models/checkpoint_memory.dart';
import '../models/model_catalog.dart';
import '../models/runtime_setup.dart';

class RuntimeCapabilityPanel extends StatelessWidget {
  const RuntimeCapabilityPanel({
    super.key,
    required this.report,
    this.memory,
    required this.selected,
    required this.backend,
  });
  final RuntimeCapabilities? report;
  final ModelHardware? memory;
  final ModelCandidate? selected;
  final RuntimeBackend backend;

  String _size(int? bytes, {bool positive = false}) =>
      bytes == null || bytes < (positive ? 1 : 0)
      ? 'unknown'
      : memorySize(bytes);

  @override
  Widget build(BuildContext context) {
    final current = report;
    if (current == null) {
      return const Padding(
        padding: EdgeInsets.only(bottom: 12),
        child: Text(
          'Capabilities not inspected for this selection. Inspect uses the chosen Python to check dependencies and device availability without loading weights or installing packages.',
        ),
      );
    }
    final estimate = CheckpointMemory.assess(
      capabilities: current,
      backend: backend,
      model: selected,
      memory: memory,
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Detected host: ${current.host}'),
          Text(
            'Host RAM: ${_size(memory?.memoryBytes, positive: true)}; '
            'free/reclaimable: ${_size(memory?.availableBytes)}.',
          ),
          const Text(
            'Read-only snapshot of this app host, not GPU memory or model fit. '
            'Memory changes as other apps run; inspect again to refresh. '
            'Unknown values require a supported native host and readable OS probes.',
          ),
          Text(
            'Selected checkpoint weights on disk: '
            '${_size(selected?.supported == true ? selected?.weightBytes : null, positive: true)}.',
          ),
          const Text(
            'File sizes only; runtime peak memory also needs cache, activations and overhead. '
            'Disk size alone is not a model-fit estimate or inference-readiness verdict. Rescan after changing files.',
          ),
          const SizedBox(height: 8),
          const Text('Selected checkpoint memory estimate'),
          Text(estimate.detail),
          if (estimate.workingBytes != null) ...[
            Text(
              'Estimated working memory: ${memorySize(estimate.workingBytes!)}; '
              'plus ${memorySize(CheckpointMemory.reserveBytes)} reserved for OS/apps.',
            ),
            const Text(
              'Heuristic: 1.25 × measured weight bytes + 4 GiB for runtime/cache. '
              'Context and architecture can require more. No loaded-model RAM credit; '
              'this snapshot does not gate launch or verify inference.',
            ),
          ],
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
            'CPU/CUDA unavailable. No measured memory adequacy check or successful inference is implied. Launch validates the actual device and model load.',
          ),
        ],
      ),
    );
  }
}
