// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_edit_request.dart';
import '../models/imported_commit_edit_observation.dart';

abstract interface class ImportedCommitEditHost {
  bool get supported;
  bool get cleanupConfirmed;

  /// A late/stopped receipt is recovery evidence, never current success.
  ImportedCommitEditObservation? get lastObservation;
  Future<ImportedCommitEditObservation> prepare(
    ImportedCommitEditRequest request,
  );
  Future<void> cancel();
  Future<void> dispose();
}
