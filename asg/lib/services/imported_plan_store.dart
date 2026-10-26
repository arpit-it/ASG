import 'dart:convert';

import '../models/imported_plan.dart';
import '../models/project_inspection.dart';
import 'inspected_folder_store.dart';
import 'record_storage.dart';
import 'requirements_store.dart';

class ImportedPlanStore {
  ImportedPlanStore(this.records);
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
  }) async {
    final writers = _writers[records] ??= <String>{};
    if (!writers.add(inspection.root)) {
      throw StateError('Plan is being saved. Retry shortly.');
    }
    try {
      ImportedPlan.validateText(text);
      final current = load(inspection.root);
      if (jsonEncode(current?.toJson()) != jsonEncode(expected?.toJson())) {
        throw StateError('Plan changed. Reopen before saving.');
      }
      final currentContext = context(inspection);
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
      if (!await records.setString(
        key(inspection.root),
        jsonEncode(result.toJson()),
      )) {
        throw StateError('Plan could not be saved. Retry the action.');
      }
      return result;
    } finally {
      writers.remove(inspection.root);
    }
  }
}
