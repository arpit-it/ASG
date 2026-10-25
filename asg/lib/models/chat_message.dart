class ChatMessage {
  const ChatMessage({required this.role, required this.content});
  final String role, content;
  factory ChatMessage.fromJson(Map<String, dynamic> json) => ChatMessage(
    role: json['role'] as String,
    content: json['content'] as String,
  );
  Map<String, String> toJson() => {'role': role, 'content': content};
}
