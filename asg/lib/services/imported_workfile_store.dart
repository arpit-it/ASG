// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_index_observation.dart';
import '../models/imported_workfile_comparison.dart';
import 'imported_commit_copy_store.dart';
import 'inspected_folder_store.dart';
import 'record_storage.dart';
import 'runtime_setup_store.dart';

final class ImportedWorkfileInputSnapshot {
  ImportedWorkfileInputSnapshot._(
    this.request,
    this.indexRequest,
    this.indexObservation,
    Map<String, String?> inputs,
  ) : inputs = Map.unmodifiable(inputs);
  final ImportedWorkfileRequest request;
  final ImportedIndexReadRequest indexRequest;
  final ImportedIndexObservation indexObservation;
  final Map<String, String?> inputs;
}

/// Zero-update durable fences, sharing the existing source-worker ownership.
class ImportedWorkfileStore {
  ImportedWorkfileStore(this.records);
  final RecordStorage records;
  static const runtimeKey = 'studio.runtimeSetup.v1';
  ImportedCommitCopyStore get _source => ImportedCommitCopyStore(records);
  bool get readBusy => _source.readBusy;
  Object acquire() => _source.acquire();
  void release(Object token) => _source.release(token);
  void requireLease(Object token) => _source.requireLease(token);
  void requireInputs(Map<String, String?> inputs) =>
      _source.requireInputs(inputs);

  ImportedWorkfileInputSnapshot read({
    required String root,
    required ImportedIndexReadRequest indexRequest,
    required ImportedIndexObservation indexObservation,
    required List<String> paths,
    required String comparisonId,
  }) {
    final inputs = {
      runtimeKey: records.getString(runtimeKey),
      InspectedFolderStore.key: records.getString(InspectedFolderStore.key),
    };
    if (indexRequest.root != root ||
        !InspectedFolderStore(records).load().contains(root) ||
        RuntimeSetupStore(records).load().python != indexRequest.python) {
      throw StateError(
        'The current folder, interpreter or index read changed.',
      );
    }
    final request = ImportedWorkfileRequest.create(
      indexRequest: indexRequest,
      indexObservation: indexObservation,
      paths: paths,
      comparisonId: comparisonId,
    );
    requireInputs(inputs);
    return ImportedWorkfileInputSnapshot._(
      request,
      indexRequest,
      indexObservation,
      inputs,
    );
  }

  Future<void> verify(
    ImportedWorkfileInputSnapshot selected,
    void Function() alive,
  ) async {
    final rebuilt = read(
      root: selected.request.root,
      indexRequest: selected.indexRequest,
      indexObservation: selected.indexObservation,
      paths: selected.request.files.map((f) => f.path).toList(),
      comparisonId: selected.request.comparisonId,
    );
    if (!rebuilt.request.matches(selected.request)) {
      throw StateError('Comparison inputs changed.');
    }
    await _source.verify(selected.inputs, alive);
  }
}
