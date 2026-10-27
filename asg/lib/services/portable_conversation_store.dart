// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/chat_message.dart';
import 'record_storage.dart';

/// Validates saved assistance fields before the portable schema drops context.
/// Future or damaged fields must never be silently lost during backup.
class PortableConversationStore {
  PortableConversationStore(this.records);
  final RecordStorage records;

  List<ChatMessage> load(String id) {
    final raw = records.getString('studio.chat.v1.$id');
    if (raw == null) return const [];
    final rows = jsonDecode(raw);
    if (rows is! List) {
      throw const FormatException('Malformed saved assistance conversation.');
    }
    return rows.map((row) {
      if (row is! Map<String, dynamic> ||
          row.keys.any(
            (key) => !const ['role', 'content', 'planContext'].contains(key),
          )) {
        throw const FormatException('Unsupported saved assistance fields.');
      }
      return ChatMessage.fromJson(row);
    }).toList();
  }
}
