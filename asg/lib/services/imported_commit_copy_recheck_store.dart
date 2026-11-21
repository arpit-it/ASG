// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_copy_recheck.dart';
import 'imported_commit_copy_store.dart';
import 'inspected_folder_store.dart';
import 'record_storage.dart';
import 'runtime_setup_store.dart';

final class ImportedCommitCopyRecheckSelection {
  ImportedCommitCopyRecheckSelection._(
    this.request,
    Map<String, String?> inputs,
  ) : inputs = Map.unmodifiable(inputs);
  final ImportedCommitCopyRecheckRequest request;
  final Map<String, String?> inputs;
}

/// Zero-update durable admission only. Rechecking never changes saved history.
class ImportedCommitCopyRecheckStore {
  ImportedCommitCopyRecheckStore(this.records);
  final RecordStorage records;
  static const runtimeKey = 'studio.runtimeSetup.v1';
  ImportedCommitCopyStore get _copies => ImportedCommitCopyStore(records);
  bool get readBusy => _copies.readBusy;
  Object acquire() => _copies.acquire();
  void release(Object token) => _copies.release(token);
  void requireLease(Object token) => _copies.requireLease(token);
  void requireInputs(Map<String, String?> inputs) =>
      _copies.requireInputs(inputs);
  ImportedCommitCopyRecheckSelection read(
    String root,
    String recheckId, {
    String? expectedHistoryDigest,
  }) {
    final history = _copies.history(root);
    final runtime = records.getString(runtimeKey),
        folders = records.getString(InspectedFolderStore.key);
    if (!InspectedFolderStore(records).load().contains(root) ||
        (expectedHistoryDigest != null &&
            history.record.digest != expectedHistoryDigest)) {
      throw StateError('Selected saved copy changed. Reopen its history.');
    }
    final request = ImportedCommitCopyRecheckRequest.create(
      history: history.record,
      python: RuntimeSetupStore(records).load().python,
      recheckId: recheckId,
    );
    final inputs = {
      ...history.inputs,
      runtimeKey: runtime,
      InspectedFolderStore.key: folders,
    };
    requireInputs(inputs);
    return ImportedCommitCopyRecheckSelection._(request, inputs);
  }

  Future<void> verify(
    ImportedCommitCopyRecheckSelection selected,
    void Function() alive,
  ) async {
    final rebuilt = read(
      selected.request.root,
      selected.request.recheckId,
      expectedHistoryDigest: selected.request.historyDigest,
    );
    if (!rebuilt.request.matches(selected.request) ||
        rebuilt.inputs.length != selected.inputs.length ||
        rebuilt.inputs.keys.any((k) => !selected.inputs.containsKey(k))) {
      throw StateError('Recheck inputs changed. Reopen saved copy history.');
    }
    await _copies.verify(selected.inputs, alive);
  }
}
