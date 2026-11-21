// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_edit_comparison.dart';
import 'imported_commit_copy_store.dart';
import 'imported_commit_edit_store.dart';
import 'inspected_folder_store.dart';
import 'record_storage.dart';
import 'runtime_setup_store.dart';

final class ImportedCommitEditComparisonSelection {
  ImportedCommitEditComparisonSelection._(
    this.request,
    Map<String, String?> inputs,
  ) : inputs = Map.unmodifiable(inputs);
  final ImportedCommitEditComparisonRequest request;
  final Map<String, String?> inputs;
}

/// Read-only durable admission. Never updates either journal or grants approval.
class ImportedCommitEditComparisonStore {
  ImportedCommitEditComparisonStore(this.records);
  final RecordStorage records;
  static const runtimeKey = 'studio.runtimeSetup.v1';
  ImportedCommitCopyStore get _copies => ImportedCommitCopyStore(records);
  bool get readBusy => _copies.readBusy;
  Object acquire() => _copies.acquire();
  void release(Object token) => _copies.release(token);
  void requireLease(Object token) => _copies.requireLease(token);
  void requireInputs(Map<String, String?> inputs) =>
      _copies.requireInputs(inputs);
  ImportedCommitEditComparisonSelection read(
    String root,
    String comparisonId, {
    String? expectedEditHistoryDigest,
  }) {
    final original = _copies.history(root),
        edits = ImportedCommitEditStore(records).history(root);
    final runtime = records.getString(runtimeKey),
        folders = records.getString(InspectedFolderStore.key);
    if (!InspectedFolderStore(records).load().contains(root) ||
        (expectedEditHistoryDigest != null &&
            edits.record.digest != expectedEditHistoryDigest)) {
      throw StateError(
        'Selected proposed-copy history changed. Reopen history.',
      );
    }
    final request = ImportedCommitEditComparisonRequest.create(
      copyHistory: original.record,
      editHistory: edits.record,
      python: RuntimeSetupStore(records).load().python,
      comparisonId: comparisonId,
    );
    final inputs = {
      ...original.inputs,
      ...edits.inputs,
      runtimeKey: runtime,
      InspectedFolderStore.key: folders,
    };
    requireInputs(inputs);
    return ImportedCommitEditComparisonSelection._(request, inputs);
  }

  Future<void> verify(
    ImportedCommitEditComparisonSelection selected,
    void Function() alive,
  ) async {
    final rebuilt = read(
      selected.request.root,
      selected.request.comparisonId,
      expectedEditHistoryDigest: selected.request.editHistoryDigest,
    );
    if (!rebuilt.request.matches(selected.request) ||
        rebuilt.inputs.length != selected.inputs.length ||
        rebuilt.inputs.keys.any((k) => !selected.inputs.containsKey(k))) {
      throw StateError('Saved comparison inputs changed. Reopen history.');
    }
    await _copies.verify(selected.inputs, alive);
  }
}
