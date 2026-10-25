import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'record_storage.dart';
import 'studio_database.dart';

import '../models/chat_message.dart';

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

  static Future<ConversationStore> open() async =>
      ConversationStore(await StudioDatabase.open());
}
