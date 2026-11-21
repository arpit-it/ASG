// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_workfile_comparison.dart';
import '../models/imported_head_index_observation.dart';
import 'imported_commit_copy_store.dart';
import 'inspected_folder_store.dart';
import 'record_storage.dart';
import 'runtime_setup_store.dart';

final class ImportedHeadIndexInputSnapshot {
  ImportedHeadIndexInputSnapshot._(
    this.request,
    this.workfileRequest,
    this.workfileObservation,
    Map<String, String?> inputs,
  ) : inputs = Map.unmodifiable(inputs);
  final ImportedHeadIndexRequest request;
  final ImportedWorkfileRequest workfileRequest;
  final ImportedWorkfileObservation workfileObservation;
  final Map<String, String?> inputs;
}

/// Zero-update durable fences; original source-worker ownership is shared.
class ImportedHeadIndexStore {
  ImportedHeadIndexStore(this.records);
  final RecordStorage records;
  static const runtimeKey = 'studio.runtimeSetup.v1';
  ImportedCommitCopyStore get _source => ImportedCommitCopyStore(records);
  bool get readBusy => _source.readBusy;
  Object acquire() => _source.acquire();
  void release(Object token) => _source.release(token);
  void requireLease(Object token) => _source.requireLease(token);
  void requireInputs(Map<String, String?> inputs) =>
      _source.requireInputs(inputs);
  ImportedHeadIndexInputSnapshot read({
    required String root,
    required ImportedWorkfileRequest workfileRequest,
    required ImportedWorkfileObservation workfileObservation,
    required String readId,
  }) {
    final inputs = {
      runtimeKey: records.getString(runtimeKey),
      InspectedFolderStore.key: records.getString(InspectedFolderStore.key),
    };
    if (workfileRequest.root != root ||
        !InspectedFolderStore(records).load().contains(root) ||
        RuntimeSetupStore(records).load().python != workfileRequest.python) {
      throw StateError('Current folder or interpreter changed.');
    }
    final request = ImportedHeadIndexRequest.create(
      workfileRequest: workfileRequest,
      workfileObservation: workfileObservation,
      readId: readId,
    );
    requireInputs(inputs);
    return ImportedHeadIndexInputSnapshot._(
      request,
      workfileRequest,
      workfileObservation,
      inputs,
    );
  }

  Future<void> verify(
    ImportedHeadIndexInputSnapshot selected,
    void Function() alive,
  ) async {
    final rebuilt = read(
      root: selected.request.root,
      workfileRequest: selected.workfileRequest,
      workfileObservation: selected.workfileObservation,
      readId: selected.request.readId,
    );
    if (!rebuilt.request.matches(selected.request)) {
      throw StateError('Declared-object inputs changed.');
    }
    await _source.verify(selected.inputs, alive);
  }
}
