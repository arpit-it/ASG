// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/ask_conversation.dart';
import 'record_storage.dart';

class AskStore {
  AskStore(this.records);
  final RecordStorage records;
  static const key = 'studio.ask.v1';
  static const maxConversations = 100;

  static List<AskConversation> decode(String? raw) {
    if (raw == null) return [];
    final data = jsonDecode(raw);
    if (data is! Map ||
        data['version'] != 1 ||
        data['conversations'] is! List) {
      throw const FormatException('Invalid Ask history.');
    }
    final conversations = (data['conversations'] as List)
        .map(
          (c) => AskConversation.fromJson(Map<String, dynamic>.from(c as Map)),
        )
        .toList();
    if (conversations.length > maxConversations ||
        conversations.map((c) => c.id).toSet().length != conversations.length) {
      throw const FormatException('Invalid Ask history.');
    }
    return List.unmodifiable(conversations);
  }

  List<AskConversation> load() => decode(records.getString(key));

  static String encode(List<AskConversation> history) => jsonEncode({
    'version': 1,
    'conversations': history.map((c) => c.toJson()).toList(),
  });

  Future<void> save(
    List<AskConversation> before,
    List<AskConversation> after,
  ) async {
    final raw = records.getString(key);
    if (encode(decode(raw)) != encode(before)) {
      throw StateError('Ask history changed. Reopen before saving.');
    }
    final next = encode(after);
    decode(next);
    final storage = records;
    if (storage is ConditionalRecordStorage) {
      await storage.commitRecords(
        expected: {key: raw},
        updates: {key: next},
        authorize: () {},
      );
    } else if (!await storage.setString(key, next)) {
      throw StateError('Ask history could not be saved.');
    }
  }
}
