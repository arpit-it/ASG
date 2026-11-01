// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'local_model_config.dart';

/// A reusable connection draft, never evidence of model compatibility/readiness.
class ModelConnectionPreset {
  const ModelConnectionPreset({required this.name, required this.config});
  final String name;
  final LocalModelConfig config;
  static const maxPresets = 20;

  void validate() {
    if (name.trim() != name ||
        name.isEmpty ||
        name.length > 64 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch(name) ||
        config.baseUrl.length > 512 ||
        config.model.length > 256) {
      throw const FormatException('Invalid connection preset.');
    }
    config.endpoint;
    config.validateChatLimit();
  }

  Map<String, Object> toJson() {
    validate();
    return {
      'name': name,
      'baseUrl': config.baseUrl,
      'model': config.model,
      'chatOutputTokens': config.chatOutputTokens,
    };
  }

  factory ModelConnectionPreset.fromJson(Object? value) {
    if (value is! Map<String, dynamic> ||
        value.length != 4 ||
        value['name'] is! String ||
        value['baseUrl'] is! String ||
        value['model'] is! String ||
        value['chatOutputTokens'] is! int) {
      throw const FormatException('Invalid saved connection preset.');
    }
    final preset = ModelConnectionPreset(
      name: value['name'] as String,
      config: LocalModelConfig(
        baseUrl: value['baseUrl'] as String,
        model: value['model'] as String,
        chatOutputTokens: value['chatOutputTokens'] as int,
      ),
    );
    preset.validate();
    return preset;
  }
}
