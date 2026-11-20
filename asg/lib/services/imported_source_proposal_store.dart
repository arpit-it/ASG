// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_plan.dart';
import '../models/imported_source_context.dart';
import '../models/project_inspection.dart';
import 'imported_plan_store.dart';
import 'inspected_folder_store.dart';
import 'record_storage.dart';
import 'requirements_store.dart';

/// Reads planning inputs only. Conditional storage is used with zero updates.
class ImportedSourceProposalStore {
  ImportedSourceProposalStore(this.records);
  final RecordStorage records;
  static const _changed =
      'Saved source planning inputs changed. Reopen review.';

  ({ImportedPlan plan, Map<String, String?> inputs}) read(
    ProjectInspection inspection,
    ImportedSourceContext context,
  ) {
    try {
      final keys = [
        InspectedFolderStore.key,
        RequirementsStore.key(
          InspectedFolderStore.workspaceId(inspection.root),
        ),
        ImportedPlanStore.key(inspection.root),
      ];
      final inputs = {for (final key in keys) key: records.getString(key)};
      final plan = ImportedPlanStore(
        records,
        capturedSource: context,
      ).load(inspection.root);
      if (plan == null ||
          !plan.approved ||
          plan.context != context.recordJson ||
          !InspectedFolderStore(records).load().contains(inspection.root) ||
          !context.matchesPlanningInputs(
            inspection,
            RequirementsStore(records)
                .load(InspectedFolderStore.workspaceId(inspection.root)),
          )) {
        throw StateError(_changed);
      }
      requireInputs(inputs);
      return (plan: plan, inputs: Map.unmodifiable(inputs));
    } catch (_) {
      throw StateError(_changed);
    }
  }

  void requireInputs(Map<String, String?> inputs) {
    if (inputs.entries.any((e) => records.getString(e.key) != e.value)) {
      throw StateError(_changed);
    }
  }

  Future<void> verify(
    Map<String, String?> inputs,
    void Function() alive,
  ) async {
    void check() {
      alive();
      requireInputs(inputs);
    }

    try {
      check();
      final storage = records;
      if (storage is ConditionalRecordStorage) {
        await storage.commitRecords(
          expected: inputs,
          updates: const {},
          authorize: check,
        );
      }
      check();
    } catch (_) {
      throw StateError(_changed);
    }
  }
}
