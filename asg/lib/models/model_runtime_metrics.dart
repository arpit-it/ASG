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

  Map<String, Object?> toJson() {
    final value = <String, Object?>{
      'prompt_tokens': promptTokens,
      'completion_tokens': completionTokens,
      'tokens_per_second': tokensPerSecond,
      'peak_memory_gb': peakMemoryGb,
    };
    ModelRuntimeMetrics.fromJson(value);
    return value;
  }

  /// Durable metadata is strict; corruption must never become missing telemetry.
  factory ModelRuntimeMetrics.fromJson(Object? value) {
    const invalid = FormatException('Invalid saved runtime metrics.');
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        !value.keys.toSet().containsAll([
          'prompt_tokens',
          'completion_tokens',
          'tokens_per_second',
          'peak_memory_gb',
        ])) {
      throw invalid;
    }
    final parsed = parse({...value, 'finish_reason': 'stop'}, outputLimit: 256);
    if (parsed == null ||
        (value['tokens_per_second'] != null &&
            parsed.tokensPerSecond == null) ||
        (value['peak_memory_gb'] != null && parsed.peakMemoryGb == null)) {
      throw invalid;
    }
    return parsed;
  }

  static const guidance =
      'Temporary server-reported metrics from this completed test only. '
      'Token counts, generation speed and process peak memory are server '
      'assertions, not independent app measurements or verified model identity, '
      'context capacity, available memory or support. Saved only when you explicitly save the test observation.';

  static const historicalGuidance =
      'Historical server-reported metrics from the saved completed test. '
      'The server and loaded weights may have changed. Token counts, speed and '
      'process peak memory are unverified server assertions, not independent '
      'measurements, available memory, context capacity or model support.';

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
