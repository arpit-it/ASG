// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Optional server assertions from a completed response, never local measurements.
class ModelRuntimeMetrics {
  const ModelRuntimeMetrics({
    required this.promptTokens,
    required this.completionTokens,
    this.tokensPerSecond,
    this.peakMemoryGb,
  });

  final int promptTokens, completionTokens;
  final double? tokensPerSecond, peakMemoryGb;

  static const guidance =
      'Temporary server-reported metrics from this completed test only. '
      'Token counts, generation speed and process peak memory are server '
      'assertions, not independent app measurements or verified model identity, '
      'context capacity, available memory or support. Not saved with test observations.';

  /// Malformed optional telemetry is unavailable; it cannot invalidate text.
  static ModelRuntimeMetrics? parse(Object? value, {required int outputLimit}) {
    if (value is! Map || value['finish_reason'] != 'stop') return null;
    final prompt = value['prompt_tokens'];
    final completion = value['completion_tokens'];
    if (prompt is! int ||
        prompt < 0 ||
        prompt > 2147483647 ||
        completion is! int ||
        completion < 0 ||
        completion > outputLimit) {
      return null;
    }
    double? number(String key) {
      final raw = value[key];
      if (raw is! num || !raw.isFinite || raw < 0 || raw > 1000000000) {
        return null;
      }
      return raw.toDouble();
    }

    return ModelRuntimeMetrics(
      promptTokens: prompt,
      completionTokens: completion,
      tokensPerSecond: number('tokens_per_second'),
      peakMemoryGb: number('peak_memory_gb'),
    );
  }
}
