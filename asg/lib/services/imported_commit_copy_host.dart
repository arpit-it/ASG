// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_copy_request.dart';
import '../models/imported_commit_copy_observation.dart';

abstract interface class ImportedCommitCopyHost {
  bool get supported;
  bool get cleanupConfirmed;

  /// A late/stopped receipt is recovery evidence, never current success.
  ImportedCommitCopyObservation? get lastObservation;
  Future<ImportedCommitCopyObservation> prepare(
    ImportedCommitCopyRequest request,
  );
  Future<void> cancel();
  Future<void> dispose();
}
