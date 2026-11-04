// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Advisory observations of parsed HTML and CSS, never an execution approval.
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
      'HTML/CSS reference diagnostics: $elements elements, $references references, '
      '$findings findings.';
  static const limitations =
      'Advisory parsed HTML href/src/action/poster/data and ID checks only. '
      'Declared button/input formaction URLs are inspected independently of '
      'form action; effective submission, control type/disabled state, form '
      'ownership, methods, validation and server behavior are not checked. '
      'Responsive img/source srcset and link imagesrcset candidate URLs with '
      'no descriptor, one positive width or one nonnegative finite density are '
      'inspected; malformed/unsupported descriptors are reported and skipped. '
      'Parsed CSS url()/@import references in styles.css and inline styles are '
      'also advisory; CSS syntax/compatibility, filter declarations, escaped URLs, JavaScript, '
      'responsive candidate selection, sizes/media/type conditions, image decoding, '
      'SVG content and its internal references, template content, dynamic references, browser '
      'behavior and visual acceptance are not checked. No files or URLs are '
      'opened. No safety verdict, preview or execution approval.';
}
