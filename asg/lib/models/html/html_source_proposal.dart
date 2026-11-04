// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../structured_proposal_json.dart';

/// Untrusted source for review only. This is not HTML validation, approval,
/// execution permission or a replacement for the fixed starter identity check.
class HtmlSourceProposal {
  HtmlSourceProposal._(this.summary, Map<String, String> files)
    : files = Map.unmodifiable(files);

  static const maxResponse = 128000;
  static const maxFile = 64000;
  final String summary;
  final Map<String, String> files;

  factory HtmlSourceProposal.decode(String response) {
    if (response.length > maxResponse ||
        utf8.encode(response).length > maxResponse) {
      throw const FormatException('HTML proposal response is too large.');
    }
    final raw = jsonDecode(response);
    rejectDuplicateJsonMembers(response);
    if (raw is! Map ||
        raw.length != 2 ||
        !raw.containsKey('summary') ||
        !raw.containsKey('files')) {
      throw const FormatException('Expected summary and files only.');
    }
    final summary = raw['summary'];
    final entries = raw['files'];
    if (summary is! String ||
        summary.trim().isEmpty ||
        summary.length > 1000 ||
        entries is! Map ||
        entries.length < 2 ||
        entries.length > 3 ||
        !entries.containsKey('index.html') ||
        !entries.containsKey('styles.css')) {
      throw const FormatException('Invalid HTML proposal fields.');
    }
    final files = <String, String>{};
    for (final entry in entries.entries) {
      final name = entry.key;
      final text = entry.value;
      if (!const ['index.html', 'styles.css', 'app.js'].contains(name) ||
          text is! String ||
          text.trim().isEmpty ||
          text.length > maxFile ||
          utf8.encode(text).length > maxFile ||
          text.contains('\u0000')) {
        throw const FormatException('Invalid HTML proposal file.');
      }
      files[name as String] = text;
    }
    return HtmlSourceProposal._(summary.trim(), files);
  }
}
