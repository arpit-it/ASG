// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_edit_comparison.dart';
import 'imported_commit_edit_comparison_host.dart';

ImportedCommitEditComparisonHost createImportedCommitEditComparisonHost() =>
    UnsupportedImportedCommitEditComparisonHost();

class UnsupportedImportedCommitEditComparisonHost
    implements ImportedCommitEditComparisonHost {
  @override
  bool get supported => false;
  @override
  bool get cleanupConfirmed => true;
  @override
  ImportedCommitEditComparisonObservation? get lastObservation => null;
  @override
  Future<ImportedCommitEditComparisonObservation> compare(
    ImportedCommitEditComparisonRequest request,
  ) async => throw StateError(
    'Proposed-copy comparison is unavailable on this platform.',
  );
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
