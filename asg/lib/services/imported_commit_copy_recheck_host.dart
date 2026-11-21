// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_copy_recheck.dart';

abstract interface class ImportedCommitCopyRecheckHost {
  bool get supported;
  bool get cleanupConfirmed;
  ImportedCommitCopyRecheckObservation? get lastObservation;
  Future<ImportedCommitCopyRecheckObservation> recheck(
    ImportedCommitCopyRecheckRequest request,
  );
  Future<void> cancel();
  Future<void> dispose();
}
