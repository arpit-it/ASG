// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Historical app-observed completion, never a verified model capability.
class ModelTestObservation {
  const ModelTestObservation({
    required this.jsonFormat,
    required this.observedAt,
    required this.firstTextMilliseconds,
    required this.completedMilliseconds,
  });

  final bool jsonFormat;
  final DateTime observedAt;
  final int firstTextMilliseconds, completedMilliseconds;
  static const outputTokens = 256;
  static const guidance =
      'Historical app-observed test at the preset’s requested connection. '
      'The server or loaded weights may have changed. This does not verify '
      'loaded identity, context capacity, general JSON/tool compatibility or '
      'model support. Latency includes connection and transport overhead; '
      'it is not token speed. Prompts and response text are not saved.';

  void validate() {
    if (!observedAt.isUtc ||
        observedAt.millisecondsSinceEpoch < 0 ||
        firstTextMilliseconds < 0 ||
        completedMilliseconds < firstTextMilliseconds ||
        completedMilliseconds > 30000) {
      throw const FormatException('Invalid model test observation.');
    }
  }

  Map<String, Object> toJson() {
    validate();
    return {
      'kind': jsonFormat ? 'jsonSentinel' : 'nonblankText',
      'observedAt': observedAt.toIso8601String(),
      'outputTokens': outputTokens,
      'firstTextMilliseconds': firstTextMilliseconds,
      'completedMilliseconds': completedMilliseconds,
    };
  }

  factory ModelTestObservation.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 5 ||
        !['jsonSentinel', 'nonblankText'].contains(value['kind']) ||
        value['observedAt'] is! String ||
        value['outputTokens'] is! int ||
        value['outputTokens'] != outputTokens ||
        value['firstTextMilliseconds'] is! int ||
        value['completedMilliseconds'] is! int) {
      throw const FormatException('Invalid saved model test observation.');
    }
    final time = DateTime.tryParse(value['observedAt'] as String);
    if (time == null || time.toIso8601String() != value['observedAt']) {
      throw const FormatException('Invalid model test observation time.');
    }
    final result = ModelTestObservation(
      jsonFormat: value['kind'] == 'jsonSentinel',
      observedAt: time,
      firstTextMilliseconds: value['firstTextMilliseconds'] as int,
      completedMilliseconds: value['completedMilliseconds'] as int,
    );
    result.validate();
    return result;
  }
}
