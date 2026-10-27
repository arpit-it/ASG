// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/requirements_board.dart';
import 'record_storage.dart';
import 'requirements_store.dart';

/// Refuses unsupported saved fields before the normal decoder can drop them.
/// This validation applies to portable export, not normal board editing.
class PortableRequirementsStore {
  PortableRequirementsStore(this.records);
  final RecordStorage records;

  RequirementsBoard load(String id) {
    final raw = records.getString(RequirementsStore.key(id));
    if (raw == null) return RequirementsBoard();
    final board = _object(jsonDecode(raw), const [
      'version',
      'revision',
      'requirements',
      'tasks',
    ]);
    for (final row in board['requirements'] as List) {
      _object(row, [
        'id',
        'title',
        'acceptance',
        if (row is Map && row.containsKey('checks')) 'checks',
      ]);
    }
    for (final row in board['tasks'] as List) {
      _object(row, const [
        'id',
        'requirementId',
        'title',
        'dependencies',
        'status',
      ]);
    }
    return RequirementsBoard.fromJson(board);
  }

  static Map<String, dynamic> _object(Object? value, List<String> keys) {
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        keys.any((key) => !value.containsKey(key))) {
      throw const FormatException('Unsupported saved requirements fields.');
    }
    return value;
  }
}
