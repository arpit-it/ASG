// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'model_request_provenance.dart';

class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    this.planContext,
    this.modelRequest,
  });
  final String role, content;
  final ModelRequestProvenance? modelRequest;
  String get modelRequestDescription =>
      modelRequest?.description ??
      'Requested model unavailable for this saved reply. Current settings do not identify past requests.';

  /// Exact project inputs captured by the app for a completed Plan response.
  /// Absent on legacy messages; model text cannot set this field.
  final String? planContext;
  factory ChatMessage.fromJson(Map<String, dynamic> json) {
    final role = json['role'] as String;
    final content = json['content'] as String;
    final context = json['planContext'] as String?;
    if (context != null && (role != 'assistant' || context.isEmpty)) {
      throw const FormatException('Invalid plan context.');
    }
    final request = json.containsKey('modelRequest')
        ? ModelRequestProvenance.fromJson(json['modelRequest'])
        : null;
    if (request != null && role != 'assistant') {
      throw const FormatException(
        'Model request metadata requires an assistant reply.',
      );
    }
    return ChatMessage(
      role: role,
      content: content,
      planContext: context,
      modelRequest: request,
    );
  }
  Map<String, Object> toJson() {
    if (modelRequest != null && role != 'assistant') {
      throw const FormatException(
        'Model request metadata requires an assistant reply.',
      );
    }
    return {
      'role': role,
      'content': content,
      'planContext': ?planContext,
      'modelRequest': ?modelRequest?.toJson(),
    };
  }
}
