// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'local_model_config.dart';

/// App-captured request settings, never proof of the server's loaded weights.
class ModelRequestProvenance {
  const ModelRequestProvenance({
    required this.model,
    required this.outputTokens,
  });
  final String model;
  final int outputTokens;

  factory ModelRequestProvenance.fromConfig(LocalModelConfig config) {
    config.endpoint;
    config.validateChatLimit();
    final result = ModelRequestProvenance(
      model: config.model,
      outputTokens: config.chatOutputTokens,
    );
    result.validate();
    return result;
  }

  void validate() {
    if (model.trim().isEmpty ||
        model.length > 4096 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(model) ||
        !LocalModelConfig.chatTokenOptions.contains(outputTokens)) {
      throw const FormatException('Invalid saved model request provenance.');
    }
  }

  factory ModelRequestProvenance.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 3 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['model'] is! String ||
        value['outputTokens'] is! int) {
      throw const FormatException('Invalid saved model request provenance.');
    }
    final result = ModelRequestProvenance(
      model: value['model'] as String,
      outputTokens: value['outputTokens'] as int,
    );
    result.validate();
    return result;
  }

  Map<String, Object> toJson() {
    validate();
    return {'version': 1, 'model': model, 'outputTokens': outputTokens};
  }

  String get description =>
      'Requested model: $model · $outputTokens output tokens. '
      'Server-loaded weights and revision are unverified.';
}
