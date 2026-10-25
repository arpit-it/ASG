import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/local_model_config.dart';

class ModelSettingsStore {
  ModelSettingsStore(this.preferences);
  final SharedPreferences preferences;
  LocalModelConfig load() {
    final raw = preferences.getString('studio.localModel.v1');
    if (raw == null) return const LocalModelConfig();
    final data = jsonDecode(raw) as Map<String, dynamic>;
    return LocalModelConfig(
      baseUrl: data['baseUrl'] as String,
      model: data['model'] as String,
    );
  }

  Future<void> save(LocalModelConfig config) async {
    config.endpoint;
    if (!await preferences.setString(
      'studio.localModel.v1',
      jsonEncode({'baseUrl': config.baseUrl, 'model': config.model}),
    )) {
      throw StateError('Unable to save local model settings.');
    }
  }
}
