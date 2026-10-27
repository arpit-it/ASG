// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/generation_event.dart';
import '../models/local_model_config.dart';

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
