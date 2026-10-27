// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'source_line_diff.dart';

/// A review artifact only. Constructing it grants no write or execution access.
class SourceEditProposal {
  SourceEditProposal._(this.summary, List<SourceReplacement> changes)
    : changes = List.unmodifiable(changes);

  static const maxFiles = 8;
  static const maxText = 32000;
  static const maxResponse = 128000;
  final String summary;
  final List<SourceReplacement> changes;

  static bool isSourcePath(String path) =>
      RegExp(r'^(lib|test)/[a-zA-Z0-9_]+(?:/[a-zA-Z0-9_]+)*\.dart$')
          .hasMatch(path);

  factory SourceEditProposal.parse(
    Object? raw, {
    required Map<String, String> originals,
  }) {
    if (raw is! Map ||
        raw.length != 2 ||
        !raw.containsKey('summary') ||
        !raw.containsKey('changes')) {
      throw const FormatException('Expected summary and changes only.');
    }
    final summary = raw['summary'];
    final entries = raw['changes'];
    if (summary is! String ||
        summary.trim().isEmpty ||
        summary.length > 1000 ||
        entries is! List ||
        entries.isEmpty ||
        entries.length > maxFiles) {
      throw const FormatException('Invalid source proposal bounds.');
    }
    final seen = <String>{};
    final changes = <SourceReplacement>[];
    for (final entry in entries) {
      if (entry is! Map ||
          entry.length != 3 ||
          !entry.containsKey('path') ||
          !entry.containsKey('before') ||
          !entry.containsKey('after')) {
        throw const FormatException('Expected path, before and after only.');
      }
      final path = entry['path'];
      final before = entry['before'];
      final after = entry['after'];
      if (path is! String ||
          !isSourcePath(path) ||
          !seen.add(path) ||
          before is! String ||
          after is! String ||
          before.length > maxText ||
          after.length > maxText ||
          after.trim().isEmpty ||
          before == after ||
          !originals.containsKey(path) ||
          originals[path] != before) {
        throw const FormatException(
          'Invalid, duplicate or stale source change.',
        );
      }
      final legalHeader = RegExp(r'^(?://[^\n]*\n)+')
          .firstMatch(before)
          ?.group(0);
      if (legalHeader != null &&
          legalHeader.contains('SPDX-License-Identifier: MPL-2.0') &&
          !after.startsWith(legalHeader)) {
        throw const FormatException(
          'Preserve the existing MPL license and copyright header verbatim in the replacement.',
        );
      }
      changes.add(SourceReplacement._(path, before, after));
    }
    return SourceEditProposal._(summary.trim(), changes);
  }
}

/// Complete original/replacement text lets a view render an unambiguous diff.
class SourceReplacement {
  SourceReplacement._(this.path, this.before, this.after);
  final String path, before, after;
  // Cache the bounded comparison so view rebuilds never repeat its work.
  late final SourceLineDiff diff = SourceLineDiff.compare(before, after);
}
