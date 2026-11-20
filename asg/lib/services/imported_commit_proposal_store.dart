// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import '../models/imported_plan.dart';
import '../models/imported_commit_proposal_record.dart';
import '../models/imported_commit_context.dart';
import '../models/project_inspection.dart';
import 'imported_plan_store.dart';
import 'inspected_folder_store.dart';
import 'record_storage.dart';
import 'requirements_store.dart';

/// Historical app records only; never reads or changes source files.
class ImportedCommitProposalStore {
  ImportedCommitProposalStore(this.records);
  final RecordStorage records;
  static const prefix = 'studio.importedCommitProposal.v1.';
  static String key(String root) =>
      '$prefix${InspectedFolderStore.workspaceId(root)}';
  bool get writable => records is ConditionalRecordStorage;
  ({ImportedCommitProposalRecord? record, Map<String, String?> inputs}) history(
    String root,
  ) {
    try {
      final target = key(root), raw = records.getString(key(root));
      final record = raw == null
          ? null
          : ImportedCommitProposalRecord.decode(raw);
      if (record != null && record.root != root) throw StateError(_changed);
      requireInputs({target: raw});
      return (record: record, inputs: Map.unmodifiable({target: raw}));
    } catch (_) {
      throw StateError(
        'Saved committed-source comparison could not be reopened.',
      );
    }
  }

  Future<void> save(
    ImportedCommitProposalRecord record,
    ProjectInspection inspection,
    Map<String, String?> inputs,
    void Function() alive,
  ) async {
    final expectedInputs = Map<String, String?>.unmodifiable(inputs);
    final target = key(record.root);
    void check() {
      alive();
      final current = read(inspection, record.context);
      if (record.root != inspection.root ||
          jsonEncode(current.plan.toJson()) !=
              jsonEncode(record.plan.toJson()) ||
          expectedInputs.length != current.inputs.length ||
          current.inputs.keys.any((k) => !expectedInputs.containsKey(k))) {
        throw StateError(_changed);
      }
      requireInputs(expectedInputs);
    }

    check();
    final checked = ImportedCommitProposalRecord.decode(record.encode());
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw StateError('Historical saving requires transactional app storage.');
    }
    await storage.commitRecords(
      expected: expectedInputs,
      updates: {target: checked.encode()},
      authorize: check,
    );
  }

  static const _changed =
      'Saved committed-source planning inputs changed. Reopen review.';

  ({ImportedPlan plan, Map<String, String?> inputs}) read(
    ProjectInspection inspection,
    ImportedCommitContext context,
  ) {
    try {
      final keys = [
        InspectedFolderStore.key,
        RequirementsStore.key(
          InspectedFolderStore.workspaceId(inspection.root),
        ),
        ImportedPlanStore.key(inspection.root),
        key(inspection.root),
      ];
      final inputs = {for (final key in keys) key: records.getString(key)};
      history(inspection.root);
      final plan = ImportedPlanStore(
        records,
        capturedCommit: context,
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
      if (storage is! ConditionalRecordStorage) throw StateError(_changed);
      await storage.commitRecords(
        expected: inputs,
        updates: const {},
        authorize: check,
      );
      check();
    } catch (_) {
      throw StateError(_changed);
    }
  }
}
