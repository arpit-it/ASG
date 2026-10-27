import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'record_storage.dart';

import '../models/local_model_config.dart';

class ModelSettingsStore {
  ModelSettingsStore(this.records);
  ModelSettingsStore.fromPreferences(SharedPreferences preferences)
    : this(PreferenceRecords(preferences));
  final RecordStorage records;
  LocalModelConfig load() {
    final raw = records.getString('studio.localModel.v1');
    if (raw == null) return const LocalModelConfig();
    final data = jsonDecode(raw) as Map<String, dynamic>;
    final tokens = data.containsKey('chatOutputTokens')
        ? data['chatOutputTokens']
        : LocalModelConfig.defaultChatOutputTokens;
    if (tokens is! int) {
      throw const FormatException('Invalid saved chat token limit.');
    }
    final config = LocalModelConfig(
      baseUrl: data['baseUrl'] as String,
      model: data['model'] as String,
      chatOutputTokens: tokens,
    );
    config.validateChatLimit();
    return config;
  }

  Future<void> save(LocalModelConfig config) async {
    config.endpoint;
    config.validateChatLimit();
    if (!await records.setString(
      'studio.localModel.v1',
      jsonEncode({
        'baseUrl': config.baseUrl,
        'model': config.model,
        'chatOutputTokens': config.chatOutputTokens,
      }),
    )) {
      throw StateError('Unable to save local model settings.');
    }
  }
}
