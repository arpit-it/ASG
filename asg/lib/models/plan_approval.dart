class PlanApproval {
  const PlanApproval({
    required this.messageIndex,
    required this.content,
    required this.context,
    required this.approved,
    required this.recordedAt,
  });
  final int messageIndex;
  final String content, context;
  final bool approved;
  final DateTime recordedAt;
  factory PlanApproval.fromJson(Map<String, dynamic> json) {
    if (json['messageIndex'] is! int ||
        (json['messageIndex'] as int) < 0 ||
        json['content'] is! String ||
        (json['content'] as String).isEmpty ||
        json['context'] is! String ||
        (json['context'] as String).isEmpty ||
        json['approved'] is! bool ||
        json['recordedAt'] is! String ||
        DateTime.tryParse(json['recordedAt'] as String) == null) {
      throw const FormatException('Invalid plan approval record.');
    }
    return PlanApproval(
      messageIndex: json['messageIndex'] as int,
      content: json['content'] as String,
      context: json['context'] as String,
      approved: json['approved'] as bool,
      recordedAt: DateTime.parse(json['recordedAt'] as String),
    );
  }
  Map<String, Object> toJson() => {
    'messageIndex': messageIndex,
    'content': content,
    'context': context,
    'approved': approved,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
  };
}
