// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_index_observation.dart';
import 'imported_commit_copy_store.dart';
import 'inspected_folder_store.dart';
import 'record_storage.dart';
import 'runtime_setup_store.dart';

final class ImportedIndexSelection {
  ImportedIndexSelection._(this.request, Map<String, String?> inputs)
    : inputs = Map.unmodifiable(inputs);
  final ImportedIndexReadRequest request;
  final Map<String, String?> inputs;
}

/// Atomic read-only input fences. Shares source ownership without journal writes.
class ImportedIndexStore {
  ImportedIndexStore(this.records);
  final RecordStorage records;
  static const runtimeKey = 'studio.runtimeSetup.v1';
  ImportedCommitCopyStore get _source => ImportedCommitCopyStore(records);
  bool get readBusy => _source.readBusy;
  Object acquire() => _source.acquire();
  void release(Object token) => _source.release(token);
  void requireLease(Object token) => _source.requireLease(token);
  void requireInputs(Map<String, String?> inputs) =>
      _source.requireInputs(inputs);

  ImportedIndexSelection read(String root, String readId) {
    final inputs = {
      runtimeKey: records.getString(runtimeKey),
      InspectedFolderStore.key: records.getString(InspectedFolderStore.key),
    };
    if (!InspectedFolderStore(records).load().contains(root)) {
      throw StateError('Inspected folder changed. Reopen it before reading.');
    }
    final request = ImportedIndexReadRequest(
      root: root,
      python: RuntimeSetupStore(records).load().python,
      readId: readId,
    );
    requireInputs(inputs);
    return ImportedIndexSelection._(request, inputs);
  }

  Future<void> verify(
    ImportedIndexSelection selected,
    void Function() alive,
  ) async {
    final rebuilt = read(selected.request.root, selected.request.readId);
    if (!rebuilt.request.matches(selected.request) ||
        rebuilt.inputs.length != selected.inputs.length ||
        rebuilt.inputs.keys.any((k) => !selected.inputs.containsKey(k))) {
      throw StateError('Index read inputs changed. Review again.');
    }
    await _source.verify(selected.inputs, alive);
  }
}
