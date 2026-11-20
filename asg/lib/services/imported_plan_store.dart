// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/imported_plan.dart';
import '../models/imported_document_context.dart';
import '../models/imported_source_context.dart';
import '../models/imported_repository_context.dart';
import '../models/project_inspection.dart';
import 'inspected_folder_store.dart';
import 'record_storage.dart';
import 'requirements_store.dart';

/// Captures the exact app-record inputs used to validate one plan save.
final class _PlanReads implements RecordStorage {
  _PlanReads(this.source);
  final RecordStorage source;
  final Map<String, String?> expected = {};
  @override
  String? getString(String key) {
    final value = source.getString(key);
    if (expected.containsKey(key) && expected[key] != value) {
      throw StateError('Planning inputs changed. Reopen review.');
    }
    expected[key] = value;
    return value;
  }

  void requireUnchanged() {
    if (expected.entries.any(
      (entry) => source.getString(entry.key) != entry.value,
    )) {
      throw StateError('Planning inputs changed. Reopen review.');
    }
  }

  @override
  Future<bool> setString(String key, String value) =>
      throw StateError('Planning input selection is read-only.');
}

class ImportedPlanStore {
  ImportedPlanStore(
    this.records, {
    this.capturedDocuments,
    this.capturedSource,
  }) {
    if (capturedDocuments != null && capturedSource != null) {
      throw ArgumentError('Choose one captured planning context.');
    }
  }
  final ImportedDocumentContext? capturedDocuments;
  final ImportedSourceContext? capturedSource;
  ImportedRepositoryContext? get capturedContext =>
      capturedSource ?? capturedDocuments;
  final RecordStorage records;
  static final _writers = Expando<Set<String>>();
  static String key(String root) =>
      'studio.importedPlan.v1.${InspectedFolderStore.workspaceId(root)}';
  String context(ProjectInspection inspection) {
    if (!InspectedFolderStore(records).load().contains(inspection.root)) {
      throw StateError('Save this folder reference before planning.');
    }
    final board = RequirementsStore(records)
        .load(InspectedFolderStore.workspaceId(inspection.root));
    board.validate();
    final captured = capturedContext;
    if (captured != null) {
      if (!captured.matchesPlanningInputs(inspection, board)) {
        throw StateError(
          captured.includesSource
              ? 'Captured planning inputs changed. Review source and requirements again.'
              : 'Captured planning inputs changed. Review documents and requirements again.',
        );
      }
      return captured.recordJson;
    }
    return jsonEncode({
      'root': inspection.root,
      'package': inspection.packageName,
      'dartSdk': inspection.dartSdk,
      'runners': inspection.runners,
      'requirements': board.toJson(),
    });
  }

  ImportedPlan? load(String root) {
    final raw = records.getString(key(root));
    return raw == null
        ? null
        : ImportedPlan.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<ImportedPlan> save(
    ProjectInspection inspection,
    ImportedPlan? expected,
    String text, {
    required bool approved,
    void Function()? authorize,
  }) async {
    final writers = _writers[records] ??= <String>{};
    if (!writers.add(inspection.root)) {
      throw StateError('Plan is being saved. Retry shortly.');
    }
    try {
      ImportedPlan.validateText(text);
      final reads = _PlanReads(records);
      void check() {
        authorize?.call();
        reads.requireUnchanged();
      }

      final snapshot = ImportedPlanStore(
        reads,
        capturedDocuments: capturedDocuments,
        capturedSource: capturedSource,
      );
      final current = snapshot.load(inspection.root);
      if (jsonEncode(current?.toJson()) != jsonEncode(expected?.toJson())) {
        throw StateError('Plan changed. Reopen before saving.');
      }
      final currentContext = snapshot.context(inspection);
      check();
      if (approved &&
          (current == null ||
              current.text != text ||
              current.context != currentContext)) {
        throw StateError('Save a current draft before approving.');
      }
      final result = ImportedPlan(
        text: text,
        context: currentContext,
        approved: approved,
        recordedAt: DateTime.now().toUtc(),
      );
      final storage = records;
      final raw = jsonEncode(result.toJson());
      if (storage is ConditionalRecordStorage) {
        await storage.commitRecords(
          expected: Map<String, String?>.unmodifiable(reads.expected),
          updates: {key(inspection.root): raw},
          authorize: check,
        );
      } else {
        check();
        if (!await storage.setString(key(inspection.root), raw)) {
          throw StateError('Plan could not be saved. Retry the action.');
        }
      }
      return result;
    } finally {
      writers.remove(inspection.root);
    }
  }
}
