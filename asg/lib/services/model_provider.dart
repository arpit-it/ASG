// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/generation_event.dart';
import '../models/local_model_config.dart';
import '../models/model_runtime_metrics.dart';

typedef ProviderFactory = ModelProvider Function(LocalModelConfig config);

/// Providers implement inference outside the UI. No inference runtime is bundled.
abstract interface class ModelProvider {
  Stream<String> generate(String prompt);
  Future<void> cancel();
}

/// Optional richer transport for actual runtime state and incremental output.
abstract interface class StreamingModelProvider implements ModelProvider {
  Stream<GenerationEvent> generateEvents(String prompt);
}

/// Optional telemetry, available only after successful stream completion.
abstract interface class ModelMetricsProvider implements ModelProvider {
  ModelRuntimeMetrics? get completedMetrics;
}
