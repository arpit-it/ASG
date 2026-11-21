// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_edit_comparison.dart';
import '../models/imported_dart_diagnostics.dart';
import 'imported_commit_copy_store.dart';
import 'imported_commit_edit_store.dart';
import 'imported_commit_edit_comparison_store.dart';
import 'record_storage.dart';

/// Read-only admission using the same four durable inputs and shared source lease.
class ImportedDartDiagnosticsStore {
  ImportedDartDiagnosticsStore(this.records);
  final RecordStorage records;
  ImportedCommitEditComparisonStore get _comparison =>
      ImportedCommitEditComparisonStore(records);
  bool get readBusy => _comparison.readBusy;
  Object acquire() => _comparison.acquire();
  void release(Object token) => _comparison.release(token);
  void requireLease(Object token) => _comparison.requireLease(token);
  void requireInputs(Map<String, String?> inputs) =>
      _comparison.requireInputs(inputs);

  ImportedCommitEditComparisonSelection select(
    ImportedCommitEditComparisonRequest compared,
    ImportedCommitEditComparisonObservation observation,
  ) {
    final current = _comparison.read(
      compared.root,
      compared.comparisonId,
      expectedEditHistoryDigest: compared.editHistoryDigest,
    );
    final decoded = ImportedCommitEditComparisonObservation.fromJson(
      observation.recordJson,
      request: compared,
    );
    if (!current.request.matches(compared) ||
        decoded.status != ImportedCommitEditComparisonStatus.matching) {
      throw StateError('A current matching copy comparison is required.');
    }
    return current;
  }

  Future<void> verify(
    ImportedCommitEditComparisonSelection selected,
    void Function() alive,
  ) => _comparison.verify(selected, alive);

  ImportedDartDiagnosticsRequest request({
    required ImportedCommitEditComparisonSelection selected,
    required ImportedCommitEditComparisonObservation observation,
    required ImportedDartSdkIdentity sdk,
    required String runId,
  }) {
    requireInputs(selected.inputs);
    return ImportedDartDiagnosticsRequest.create(
      copyHistory: ImportedCommitCopyStore(records)
          .history(selected.request.root)
          .record,
      editHistory: ImportedCommitEditStore(records)
          .history(selected.request.root)
          .record,
      compared: selected.request,
      observation: observation,
      sdk: sdk,
      python: selected.request.python,
      runId: runId,
    );
  }
}
