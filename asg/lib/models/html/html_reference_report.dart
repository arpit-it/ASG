// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Advisory observations of parsed HTML only, never an execution approval.
class HtmlReferenceReport {
  HtmlReferenceReport({
    required this.elements,
    required this.references,
    required this.findings,
    required List<String> messages,
  }) : messages = List.unmodifiable(messages);

  final int elements, references, findings;
  final List<String> messages;
  bool get truncated => findings > messages.length;
  String get summary =>
      'HTML reference diagnostics: $elements elements, $references references, '
      '$findings findings.';
  static const limitations =
      'Advisory parsed HTML href/src/action/poster/data and ID checks only. '
      'CSS, JavaScript, srcset, template content, dynamic references, browser '
      'behavior and visual acceptance are not checked. No files or URLs are '
      'opened. No safety verdict, preview or execution approval.';
}
