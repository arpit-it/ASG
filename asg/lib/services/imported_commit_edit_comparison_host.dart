// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_edit_comparison.dart';

abstract interface class ImportedCommitEditComparisonHost {
  bool get supported;
  bool get cleanupConfirmed;
  ImportedCommitEditComparisonObservation? get lastObservation;
  Future<ImportedCommitEditComparisonObservation> compare(
    ImportedCommitEditComparisonRequest request,
  );
  Future<void> cancel();
  Future<void> dispose();
}
