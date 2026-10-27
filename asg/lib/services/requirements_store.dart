// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/requirements_board.dart';
import 'record_storage.dart';

class RequirementsStore {
  RequirementsStore(this.records);
  final RecordStorage records;
  static String key(String projectId) => 'studio.requirements.v1.$projectId';
  // Serializes same-session editors through the app's shared storage instance.
  static final _writers = Expando<Set<String>>();
  RequirementsBoard load(String projectId) {
    final raw = records.getString(key(projectId));
    if (raw == null) return RequirementsBoard();
    try {
      return RequirementsBoard.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } catch (_) {
      throw const FormatException(
        'Saved requirements are unreadable. They have not been replaced.',
      );
    }
  }

  Future<RequirementsBoard> save(
    String projectId,
    RequirementsBoard original,
    RequirementsBoard draft,
  ) async {
    final writers = _writers[records] ??= <String>{};
    if (!writers.add(projectId)) {
      throw StateError(
        'Requirements are being saved. Retry after the current save.',
      );
    }
    try {
      final current = load(projectId);
      if (jsonEncode(current.toJson()) != jsonEncode(original.toJson())) {
        throw StateError(
          'Requirements changed. Reopen the board before editing.',
        );
      }
      final saved = RequirementsBoard(
        revision: current.revision + 1,
        requirements: draft.requirements,
        tasks: draft.tasks,
      );
      saved.validate();
      if (!await records.setString(
        key(projectId),
        jsonEncode(saved.toJson()),
      )) {
        throw StateError('Requirements could not be saved. Retry your edit.');
      }
      return saved;
    } finally {
      writers.remove(projectId);
    }
  }
}
