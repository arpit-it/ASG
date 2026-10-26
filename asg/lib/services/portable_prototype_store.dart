import 'dart:convert';

import '../models/portable_project_archive.dart';
import '../models/chat_message.dart';
import '../models/structured_proposal_json.dart';
import 'record_storage.dart';

/// Reads saved prototype and conversation text, excluding execution context.
class PortablePrototypeStore {
  PortablePrototypeStore(this.records);
  final RecordStorage records;
  PortablePrototype? load(String id) {
    final raw = records.getString('studio.application.v1.$id');
    if (raw == null) return null;
    rejectDuplicateJsonMembers(raw);
    final data = jsonDecode(raw);
    if (data is! Map<String, dynamic> ||
        data.length != 3 ||
        !data.containsKey('definition') ||
        !data.containsKey('revision') ||
        data['messages'] is! List) {
      throw const FormatException('Malformed saved prototype record.');
    }
    // Saved application messages may contain context, but only validated text
    // is copied to the portable schema.
    final messages = (data['messages'] as List).map((value) {
      if (value is! Map<String, dynamic> ||
          value.keys.any(
            (k) => !const ['role', 'content', 'planContext'].contains(k),
          )) {
        throw const FormatException('Malformed saved prototype conversation.');
      }
      return ChatMessage.fromJson(value);
    }).toList();
    final prototype = PortablePrototype.fromJson({
      'definition': data['definition'],
      'revision': data['revision'],
    });
    return PortablePrototype(
      definition: prototype.definition,
      revision: prototype.revision,
      messages: messages,
    );
  }
}
