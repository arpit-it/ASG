// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'local_model_config.dart';

/// App-captured request settings, never proof of the server's loaded weights.
class ModelRequestProvenance {
  const ModelRequestProvenance({
    required this.model,
    required this.outputTokens,
    this.responseModel,
  });
  // Source proposals have a fixed ceiling independent of chat options.
  static const sourceOutputTokens = 4096;
  final String model;
  final int outputTokens;
  final String? responseModel;

  ModelRequestProvenance withResponseModel(String? value) {
    if (value == null || !_validModelId(value)) return this;
    return ModelRequestProvenance(
      model: model,
      outputTokens: outputTokens,
      responseModel: value,
    );
  }

  static bool _validModelId(String value) =>
      value.trim().isNotEmpty &&
      value.length <= 4096 &&
      !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);

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
    if ((responseModel != null && !_validModelId(responseModel!)) ||
        model.trim().isEmpty ||
        model.length > 4096 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(model) ||
        ![
          ...LocalModelConfig.chatTokenOptions,
          sourceOutputTokens,
        ].contains(outputTokens)) {
      throw const FormatException('Invalid saved model request provenance.');
    }
  }

  factory ModelRequestProvenance.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value['version'] is! int ||
        !(value['version'] == 1 && value.length == 3 ||
            value['version'] == 2 &&
                value.length == 4 &&
                value['responseModel'] is String &&
                _validModelId(value['responseModel'] as String)) ||
        value['model'] is! String ||
        value['outputTokens'] is! int) {
      throw const FormatException('Invalid saved model request provenance.');
    }
    final result = ModelRequestProvenance(
      model: value['model'] as String,
      outputTokens: value['outputTokens'] as int,
      responseModel: value['version'] == 2
          ? value['responseModel'] as String
          : null,
    );
    result.validate();
    return result;
  }

  Map<String, Object> toJson() {
    validate();
    return {
      'version': responseModel == null ? 1 : 2,
      'model': model,
      'outputTokens': outputTokens,
      'responseModel': ?responseModel,
    };
  }

  String get description =>
      'Requested model: $model · $outputTokens output tokens. '
      '${responseModel == null ? '' : 'Server-reported model: $responseModel. '}'
      'Server-loaded weights and revision are unverified.';
}
