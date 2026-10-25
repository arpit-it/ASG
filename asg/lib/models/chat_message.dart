class ChatMessage {
  const ChatMessage({
    required this.role,
    required this.content,
    this.planContext,
  });
  final String role, content;

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
    return ChatMessage(role: role, content: content, planContext: context);
  }
  Map<String, String> toJson() => {
    'role': role,
    'content': content,
    'planContext': ?planContext,
  };
}
