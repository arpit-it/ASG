// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

enum CandidateChangeKind { added, modified, removed }

class CandidateFileChange {
  const CandidateFileChange(this.path, this.kind, this.executableChanged);
  final String path;
  final CandidateChangeKind kind;
  final bool executableChanged;
}

/// A file comparison with a selected baseline, not proof of candidate origin.
class CandidateComparison {
  const CandidateComparison._({
    required this.commit,
    required this.digest,
    required this.added,
    required this.modified,
    required this.removed,
    required this.executableChanged,
    required this.changes,
    required this.truncated,
  });

  final String commit, digest;
  final int added, modified, removed, executableChanged;
  final List<CandidateFileChange> changes;
  final bool truncated;

  factory CandidateComparison.decode(String source) {
    const invalid = FormatException('Invalid candidate comparison.');
    try {
      if (source.length > 32768) throw invalid;
      final value = jsonDecode(source);
      if (value is! Map<String, dynamic> ||
          value.length != 6 ||
          value['schemaVersion'] is! int ||
          value['schemaVersion'] != 1 ||
          value['commit'] is! String ||
          !RegExp(r'^[a-f0-9]{40}$').hasMatch(value['commit'] as String) ||
          value['digest'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['digest'] as String) ||
          value['counts'] is! Map<String, dynamic> ||
          value['changes'] is! List ||
          value['truncated'] is! bool) {
        throw invalid;
      }
      final counts = value['counts'] as Map<String, dynamic>;
      const keys = {'added', 'modified', 'removed', 'executableChanged'};
      if (counts.length != 4 ||
          !counts.keys.every(keys.contains) ||
          counts.values.any((v) => v is! int || v < 0 || v > 4096)) {
        throw invalid;
      }
      final added = counts['added'] as int;
      final modified = counts['modified'] as int;
      final removed = counts['removed'] as int;
      final modes = counts['executableChanged'] as int;
      if (added + modified + removed > 4096 || modes > modified) throw invalid;
      final raw = value['changes'] as List;
      if (raw.length > 100) throw invalid;
      final changes = <CandidateFileChange>[];
      var characters = 0;
      final observed = <CandidateChangeKind, int>{};
      var observedModes = 0;
      String? previous;
      for (final item in raw) {
        if (item is! Map<String, dynamic> ||
            item.length != 3 ||
            item['path'] is! String ||
            item['kind'] is! String ||
            item['executableChanged'] is! bool) {
          throw invalid;
        }
        final name = item['path'] as String;
        final parts = name.split('/');
        characters += name.length;
        if (parts.length > 16 ||
            characters > 16384 ||
            parts.any(
              (p) =>
                  !RegExp(r'^[A-Za-z0-9_. @-]{1,100}$').hasMatch(p) ||
                  {'.', '..', '.git'}.contains(p.toLowerCase()),
            ) ||
            (previous != null && previous.compareTo(name) >= 0)) {
          throw invalid;
        }
        final kind = CandidateChangeKind.values
            .where((k) => k.name == item['kind'])
            .firstOrNull;
        if (kind == null) throw invalid;
        final mode = item['executableChanged'] as bool;
        if (mode && kind != CandidateChangeKind.modified) throw invalid;
        changes.add(CandidateFileChange(name, kind, mode));
        observed[kind] = (observed[kind] ?? 0) + 1;
        if (mode) observedModes++;
        previous = name;
      }
      final total = added + modified + removed;
      final truncated = value['truncated'] as bool;
      if (truncated != (changes.length < total) ||
          (observed[CandidateChangeKind.added] ?? 0) > added ||
          (observed[CandidateChangeKind.modified] ?? 0) > modified ||
          (observed[CandidateChangeKind.removed] ?? 0) > removed ||
          observedModes > modes ||
          (!truncated && observedModes != modes)) {
        throw invalid;
      }
      return CandidateComparison._(
        commit: value['commit'] as String,
        digest: value['digest'] as String,
        added: added,
        modified: modified,
        removed: removed,
        executableChanged: modes,
        changes: List.unmodifiable(changes),
        truncated: truncated,
      );
    } on Object {
      throw invalid;
    }
  }
}
