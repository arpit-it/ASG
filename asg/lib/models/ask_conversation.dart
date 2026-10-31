// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'chat_message.dart';

/// Standalone advisory conversation; never contains project execution authority.
class AskConversation {
  AskConversation({required this.id, required List<ChatMessage> messages})
    : messages = List.unmodifiable(messages) {
    if (!RegExp(r'^ask-[1-9][0-9]*$').hasMatch(id) ||
        messages.isEmpty ||
        messages.length > maxMessages ||
        messages.first.role != 'user' ||
        messages.any(
          (m) =>
              !['user', 'assistant'].contains(m.role) ||
              m.content.trim().isEmpty ||
              m.content.length > maxMessageLength ||
              m.planContext != null,
        )) {
      throw const FormatException('Invalid standalone conversation.');
    }
  }
  static const maxMessages = 200;
  static const maxMessageLength = 24000;
  final String id;
  final List<ChatMessage> messages;
  String get title {
    final text = messages.first.content.replaceAll(RegExp(r'\s+'), ' ');
    return text.length <= 64 ? text : '${text.substring(0, 64)}…';
  }

  Map<String, Object> toJson() => {
    'id': id,
    'messages': messages.map((m) => m.toJson()).toList(),
  };
  factory AskConversation.fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String || json['messages'] is! List) {
      throw const FormatException('Invalid standalone conversation.');
    }
    return AskConversation(
      id: json['id'] as String,
      messages: (json['messages'] as List)
          .map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map)))
          .toList(),
    );
  }
}
