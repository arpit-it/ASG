// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'record_storage.dart';

/// Saved references only. Opening always requires a fresh read-only inspection.
class InspectedFolderStore {
  InspectedFolderStore(this.records);
  final RecordStorage records;
  static const key = 'studio.inspectedFolders.v1';

  /// Separate from generated project IDs; use the inspector's canonical root.
  /// Moving a folder creates a new workspace rather than merging user records.
  static String workspaceId(String root) =>
      'imported-${sha256.convert(utf8.encode(root))}';

  List<String> load() {
    final raw = records.getString(key);
    if (raw == null) return const [];
    final Object? decoded = jsonDecode(raw);
    if (decoded is! List ||
        decoded.any((root) => root is! String || root.trim().isEmpty) ||
        decoded.toSet().length != decoded.length) {
      throw const FormatException('Saved folder references are invalid.');
    }
    return List<String>.unmodifiable(decoded.cast<String>());
  }

  Future<List<String>> save(String root) async {
    if (root.trim().isEmpty) throw const FormatException('Empty folder.');
    final roots = load(); // Refuse to overwrite corrupted data.
    if (roots.contains(root)) return roots;
    final updated = [...roots, root];
    if (!await records.setString(key, jsonEncode(updated))) {
      throw StateError('Folder reference could not be saved.');
    }
    return List.unmodifiable(updated);
  }
}
