import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';

class ConversationStore {
  ConversationStore(this.preferences);
  final SharedPreferences preferences;
  List<ChatMessage> load(String projectId) {
    final raw = preferences.getString('studio.chat.v1.$projectId');
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
        .toList();
  }

  Future<void> save(String projectId, List<ChatMessage> messages) async {
    if (!await preferences.setString(
      'studio.chat.v1.$projectId',
      jsonEncode(messages.map((m) => m.toJson()).toList()),
    )) {
      throw StateError('Conversation could not be saved.');
    }
  }

  static Future<ConversationStore> open() async =>
      ConversationStore(await SharedPreferences.getInstance());
}
