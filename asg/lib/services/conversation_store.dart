// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'record_storage.dart';
import 'studio_database.dart';

import '../models/chat_message.dart';
import '../models/model_connection_preset.dart';

class ConversationStore {
  ConversationStore(this.records);
  ConversationStore.fromPreferences(SharedPreferences preferences)
    : this(PreferenceRecords(preferences));
  final RecordStorage records;
  List<ChatMessage> load(String projectId) {
    final raw = records.getString('studio.chat.v1.$projectId');
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList();
  }

  Future<void> save(String projectId, List<ChatMessage> messages) async {
    if (!await records.setString(
      'studio.chat.v1.$projectId',
      jsonEncode(messages.map((m) => m.toJson()).toList()),
    )) {
      throw StateError('Conversation could not be saved.');
    }
  }

  static const selectionPrefix = 'studio.chatConnection.v1.';

  ModelConnectionPreset? loadConnection(String projectId) {
    final raw = records.getString('$selectionPrefix$projectId');
    return raw == null ? null : decodeConnection(raw);
  }

  static ModelConnectionPreset? decodeConnection(String raw) {
    if (raw.length > 8192) {
      throw const FormatException('Saved chat connection exceeds the limit.');
    }
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data.length != 2 ||
        data['version'] is! int ||
        data['version'] != 1 ||
        !data.containsKey('preset')) {
      throw const FormatException('Invalid saved chat connection.');
    }
    return data['preset'] == null
        ? null
        : ModelConnectionPreset.fromJson(data['preset']);
  }

  static String _encodeConnection(ModelConnectionPreset? preset) =>
      jsonEncode({'version': 1, 'preset': preset?.toJson()});

  void checkConnection(String projectId, ModelConnectionPreset? expected) {
    if (_encodeConnection(loadConnection(projectId)) !=
        _encodeConnection(expected)) {
      throw StateError('Chat connection changed. Reopen before retrying.');
    }
  }

  Future<void> saveConnection(
    String projectId,
    ModelConnectionPreset? preset, {
    required ModelConnectionPreset? expected,
  }) async {
    final key = '$selectionPrefix$projectId';
    final raw = records.getString(key);
    checkConnection(projectId, expected);
    final value = _encodeConnection(preset);
    // Encoding expansion must obey the same bound as the reader.
    decodeConnection(value);
    final storage = records;
    if (storage is ConditionalRecordStorage) {
      await storage.commitRecords(
        expected: {key: raw},
        updates: {key: value},
        authorize: () {},
      );
    } else if (!await storage.setString(key, value)) {
      throw StateError('Chat connection could not be saved.');
    }
  }

  static Future<ConversationStore> open() async =>
      ConversationStore(await StudioDatabase.open());
}
