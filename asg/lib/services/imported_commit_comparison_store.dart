// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_source_observation.dart';
import '../models/imported_source_proposal_record.dart';
import 'imported_source_baseline_store.dart';
import 'record_storage.dart';

final class ImportedCommitComparisonSelection {
  ImportedCommitComparisonSelection._(this.baseline, this.request);
  final ImportedSourceBaselineSelection baseline;
  final ImportedCommitReadRequest request;
  ImportedSourceProposalRecord get saved => baseline.saved;
  Map<String, String?> get inputs => baseline.inputs;
}

/// Same five read-only app inputs and shared reader lease as baseline rechecks.
class ImportedCommitComparisonStore {
  ImportedCommitComparisonStore(RecordStorage records)
    : _baseline = ImportedSourceBaselineStore(records);
  final ImportedSourceBaselineStore _baseline;
  bool get readOwned => _baseline.readOwned;
  Object acquireRead() => _baseline.acquireRead();
  void releaseRead(Object token) => _baseline.releaseRead(token);
  void requireInputs(Map<String, String?> inputs) =>
      _baseline.requireInputs(inputs);
  ImportedCommitComparisonSelection prepare(
    ImportedSourceProposalRecord saved,
    String commit,
  ) {
    final baseline = _baseline.prepare(saved);
    return ImportedCommitComparisonSelection._(
      baseline,
      ImportedCommitReadRequest(
        root: baseline.request.root,
        python: baseline.request.python,
        commit: commit,
        selectedPaths: baseline.request.selectedPaths,
      ),
    );
  }

  Future<void> verify(
    ImportedCommitComparisonSelection selection,
    void Function() alive,
  ) => _baseline.verify(selection.baseline, alive);
}
