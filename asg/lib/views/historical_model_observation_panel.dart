// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter/material.dart';

import '../controllers/historical_model_observation_controller.dart';

class HistoricalModelObservationPanel extends StatefulWidget {
  const HistoricalModelObservationPanel({super.key, this.controller});
  final HistoricalModelObservationController? controller;
  @override
  State<HistoricalModelObservationPanel> createState() => _ObservationState();
}

class _ObservationState extends State<HistoricalModelObservationPanel> {
  late final controller =
      widget.controller ?? HistoricalModelObservationController();
  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    if (widget.controller == null) controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final report = controller.observation;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: const Text('Historical Qwen3.8 27B MLX observation'),
      onExpansionChanged: (expanded) {
        if (expanded) controller.load();
      },
      children: [
        const Text(
          'Retained isolated Qwen3.8-27B-4bit workload on an arm64 Mac. This is historical evidence, separate from the currently connected model and catalog estimates. It does not verify current loaded identity, total context capacity, other models or other platforms. It never enables selection or grants memory credit.',
        ),
        if (controller.loading) const LinearProgressIndicator(),
        if (controller.error != null) ...[
          Text(controller.error!),
          TextButton(
            onPressed: controller.load,
            child: const Text('Retry historical report'),
          ),
        ],
        if (report != null) ...[
          const SizedBox(height: 8),
          Text('Recorded: ${report.recordedAt.toIso8601String()}'),
          SelectableText('Runtime source revision: ${report.sourceRevision}'),
          Text(
            'Counted weight bytes: ${report.weightBytes} (weights not hashed).',
          ),
          for (final run in report.runs)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                '${run.label}: ${run.promptTokens} prompt / ${run.completionTokens} completion tokens; reported ${run.tokensPerSecond.toStringAsFixed(1)} tokens/s; process high-water ${run.processPeakGb.toStringAsFixed(2)} GB (decimal).',
              ),
            ),
          Text(
            'Disconnect to observed idle: ${report.disconnectSeconds.toStringAsFixed(3)} s; retry succeeded. This does not prove native-kernel preemption or process-tree cleanup.',
          ),
          const SizedBox(height: 8),
          const Text(
            'Tiny warm workloads are not sustained throughput or memory requirements. Process high-water is cumulative, not per-request allocation. Metadata and probe input hashes are retained in the reviewed report; repository revision/license and HTTP identity were not authenticated. No app/manual acceptance or verified full profile follows.',
          ),
          const SelectableText(
            'Evidence: arpit-it/ASG · docs/development/acceptance/2026-11-10-live-27b-profile/observations.json',
          ),
        ],
      ],
    );
  }
}
