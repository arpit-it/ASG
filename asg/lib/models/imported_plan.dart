// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Review consent for imported planning only; never an execution credential.
class ImportedPlan {
  const ImportedPlan({
    required this.text,
    required this.context,
    required this.approved,
    required this.recordedAt,
  });
  final String text, context;
  final bool approved;
  final DateTime recordedAt;
  static void validateText(String text) {
    if (text.trim().isEmpty || text.length > 12000) {
      throw const FormatException('Plan must contain 1–12000 characters.');
    }
  }

  factory ImportedPlan.fromJson(Map<String, dynamic> json) {
    if (json['text'] is! String ||
        json['context'] is! String ||
        (json['context'] as String).isEmpty ||
        json['approved'] is! bool ||
        json['recordedAt'] is! String ||
        DateTime.tryParse(json['recordedAt'] as String) == null) {
      throw const FormatException('Saved imported plan is unreadable.');
    }
    validateText(json['text'] as String);
    return ImportedPlan(
      text: json['text'] as String,
      context: json['context'] as String,
      approved: json['approved'] as bool,
      recordedAt: DateTime.parse(json['recordedAt'] as String),
    );
  }
  Map<String, Object> toJson() => {
    'text': text,
    'context': context,
    'approved': approved,
    'recordedAt': recordedAt.toUtc().toIso8601String(),
  };
}
