// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_advisory_request.dart';
import '../models/imported_advisory_record.dart';
import '../models/imported_document_context.dart';
import '../models/project_inspection.dart';
import 'inspected_folder_store.dart';
import 'requirements_store.dart';
import 'model_settings_store.dart';
import 'record_storage.dart';

class ImportedAdvisoryStore {
  ImportedAdvisoryStore(this.records);
  final RecordStorage records;
  static const prefix = 'studio.importedAdvisory.v1.';
  static String key(String root) =>
      '$prefix${InspectedFolderStore.workspaceId(root)}';
  ImportedAdvisoryRecord? load(String root) {
    final raw = records.getString(key(root));
    if (raw == null) return null;
    final result = ImportedAdvisoryRecord.decode(raw);
    if (result.root != root) {
      throw const FormatException('Advisory folder changed.');
    }
    return result;
  }

  ({ImportedAdvisoryRequest request, Map<String, String?> inputs}) prepare(
    ProjectInspection inspection,
    ImportedDocumentContext context,
    String question,
    ImportedAdvisoryRecord? expected,
  ) {
    final keys = [
      InspectedFolderStore.key,
      RequirementsStore.key(InspectedFolderStore.workspaceId(inspection.root)),
      'studio.localModel.v1',
      key(inspection.root),
    ];
    final inputs = {for (final k in keys) k: records.getString(k)};
    if (load(inspection.root)?.encode() != expected?.encode() ||
        !InspectedFolderStore(records).load().contains(inspection.root) ||
        !context.matchesPlanningInputs(
          inspection,
          RequirementsStore(records)
              .load(InspectedFolderStore.workspaceId(inspection.root)),
        )) {
      throw StateError('Saved advisory inputs changed. Reopen review.');
    }
    final request = ImportedAdvisoryRequest.prepare(
      question: question,
      context: context,
      config: ModelSettingsStore(records).load(),
    );
    requireInputs(inputs);
    return (request: request, inputs: Map.unmodifiable(inputs));
  }

  void requireInputs(Map<String, String?> inputs) {
    if (inputs.entries.any((e) => records.getString(e.key) != e.value)) {
      throw StateError('Saved advisory inputs changed. Reopen review.');
    }
  }

  Future<void> authorize(
    Map<String, String?> inputs,
    void Function() alive,
  ) async {
    void check() {
      alive();
      requireInputs(inputs);
    }

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
  }

  Future<void> save(
    ImportedAdvisoryRecord record,
    Map<String, String?> inputs,
    void Function() alive,
  ) async {
    final raw = record.encode();
    ImportedAdvisoryRecord.decode(raw);
    final target = key(record.root);
    if (!inputs.containsKey(target)) {
      throw StateError('Advisory record scope changed.');
    }
    void check() {
      alive();
      requireInputs(inputs);
    }

    check();
    final storage = records;
    if (storage is ConditionalRecordStorage) {
      await storage.commitRecords(
        expected: inputs,
        updates: {target: raw},
        authorize: check,
      );
    } else if (!await storage.setString(target, raw)) {
      throw StateError('Advisory answer could not be saved.');
    }
  }
}
