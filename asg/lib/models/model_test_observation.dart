// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'model_runtime_metrics.dart';
import 'model_profile_notes.dart';

/// Historical app-observed completion, never a verified model capability.
class ModelTestObservation {
  const ModelTestObservation({
    required this.jsonFormat,
    required this.observedAt,
    required this.firstTextMilliseconds,
    required this.completedMilliseconds,
    this.runtimeMetrics,
    this.responseModel,
    this.profileNotes,
  });

  final bool jsonFormat;
  final DateTime observedAt;
  final int firstTextMilliseconds, completedMilliseconds;
  final ModelRuntimeMetrics? runtimeMetrics;
  final String? responseModel;

  /// Saved preset declarations captured before dispatch, never verified identity.
  final ModelProfileNotes? profileNotes;
  static const profileGuidance =
      'Test-time saved preset notes: user-declared and unverified. Captured before '
      'this test, excluding unsaved note edits. They do not prove the server used '
      'these weights, revision, backend or context capacity.';
  static const responseModelGuidance =
      'Response model ID is an unverified server assertion from this completed '
      'historical test, not proof of loaded weights, revision or support.';
  static const outputTokens = 256;
  static const guidance =
      'Historical app-observed test at the preset’s requested connection. '
      'The server or loaded weights may have changed. This does not verify '
      'loaded identity, context capacity, general JSON/tool compatibility or '
      'model support. Latency includes connection and transport overhead; '
      'it is not token speed. Prompts and response text are not saved.';

  void validate() {
    runtimeMetrics?.toJson();
    profileNotes?.validate();
    if (responseModel != null &&
        (responseModel!.trim().isEmpty ||
            responseModel!.length > 256 ||
            RegExp(r'[\x00-\x1f\x7f]').hasMatch(responseModel!))) {
      throw const FormatException('Invalid saved response model ID.');
    }
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
      if (runtimeMetrics != null) 'runtimeMetrics': runtimeMetrics!.toJson(),
      'responseModel': ?responseModel,
      if (profileNotes != null) 'profileNotes': profileNotes!.toJson(),
    };
  }

  factory ModelTestObservation.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.keys.any(
          (key) => !const {
            'kind',
            'observedAt',
            'outputTokens',
            'firstTextMilliseconds',
            'completedMilliseconds',
            'runtimeMetrics',
            'responseModel',
            'profileNotes',
          }.contains(key),
        ) ||
        !value.keys.toSet().containsAll([
          'kind',
          'observedAt',
          'outputTokens',
          'firstTextMilliseconds',
          'completedMilliseconds',
        ]) ||
        (value.containsKey('responseModel') &&
            value['responseModel'] is! String) ||
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
      responseModel: value['responseModel'] as String?,
      profileNotes: value.containsKey('profileNotes')
          ? ModelProfileNotes.fromJson(value['profileNotes'])
          : null,
      observedAt: time,
      firstTextMilliseconds: value['firstTextMilliseconds'] as int,
      completedMilliseconds: value['completedMilliseconds'] as int,
      runtimeMetrics: value.containsKey('runtimeMetrics')
          ? ModelRuntimeMetrics.fromJson(value['runtimeMetrics'])
          : null,
    );
    result.validate();
    return result;
  }
}
