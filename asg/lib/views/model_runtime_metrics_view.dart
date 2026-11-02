// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/model_runtime_metrics.dart';

class ModelRuntimeMetricsView extends StatelessWidget {
  const ModelRuntimeMetricsView({super.key, required this.metrics});
  final ModelRuntimeMetrics metrics;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'Server-reported test tokens: ${metrics.promptTokens} prompt; '
        '${metrics.completionTokens} completion.\n'
        'Server-reported generation speed: ${metrics.tokensPerSecond?.toStringAsFixed(2) ?? 'unavailable'} tokens/s.\n'
        'Server-reported process peak memory: ${metrics.peakMemoryGb?.toStringAsFixed(2) ?? 'unavailable'} GB.',
      ),
      const Text(ModelRuntimeMetrics.guidance),
    ],
  );
}
