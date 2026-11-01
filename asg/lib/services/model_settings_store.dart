// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'record_storage.dart';

import '../models/local_model_config.dart';
import '../models/model_connection_preset.dart';

class ModelSettingsStore {
  ModelSettingsStore(this.records);
  ModelSettingsStore.fromPreferences(SharedPreferences preferences)
    : this(PreferenceRecords(preferences));
  final RecordStorage records;
  static const presetsKey = 'studio.modelConnectionPresets.v1';

  List<ModelConnectionPreset> loadPresets() {
    final raw = records.getString(presetsKey);
    if (raw == null) return const [];
    return decodePresets(raw);
  }

  static List<ModelConnectionPreset> decodePresets(String raw) {
    if (raw.length > 65536) {
      throw const FormatException('Saved connection presets exceed the limit.');
    }
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data.length != 2 ||
        data['version'] != 1 ||
        data['version'] is! int ||
        data['presets'] is! List) {
      throw const FormatException('Invalid saved connection presets.');
    }
    final presets = (data['presets'] as List)
        .map(ModelConnectionPreset.fromJson)
        .toList();
    _validatePresets(presets);
    return List.unmodifiable(presets);
  }

  static void _validatePresets(List<ModelConnectionPreset> presets) {
    if (presets.length > ModelConnectionPreset.maxPresets ||
        presets.map((p) => p.name).toSet().length != presets.length) {
      throw const FormatException('Connection preset limit or duplicate name.');
    }
    for (final preset in presets) {
      preset.validate();
    }
  }

  static String _encodePresets(List<ModelConnectionPreset> presets) {
    final value = jsonEncode({
      'version': 1,
      'presets': presets.map((p) => p.toJson()).toList(),
    });
    // JSON escaping can expand individually bounded fields beyond the reader's
    // whole-record limit. Every storage adapter must preserve round trips.
    if (value.length > 65536) {
      throw const FormatException(
        'Connection presets exceed the saved record limit.',
      );
    }
    return value;
  }

  Future<void> savePresets(
    List<ModelConnectionPreset> presets, {
    List<ModelConnectionPreset>? expected,
  }) async {
    _validatePresets(presets);
    final raw = records.getString(presetsKey);
    final current = raw == null
        ? <ModelConnectionPreset>[]
        : decodePresets(raw);
    if (expected != null &&
        _encodePresets(current) != _encodePresets(expected)) {
      throw StateError(
        'Presets changed; close and reopen settings before retrying.',
      );
    }
    final value = _encodePresets(presets);
    final storage = records;
    if (storage is ConditionalRecordStorage) {
      await storage.commitRecords(
        expected: {presetsKey: raw},
        updates: {presetsKey: value},
        authorize: () {},
      );
    } else if (!await storage.setString(presetsKey, value)) {
      throw StateError('Unable to save connection presets.');
    }
  }

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
