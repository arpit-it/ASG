// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/imported_commit_source_observation.dart';

/// Owns only the trusted bounded source reader, never project commands.
abstract interface class ImportedCommitSourceHost {
  bool get supported;
  Future<ImportedCommitSourceObservation> inspect(
    ImportedCommitReadRequest request,
  );

  /// Waits for owned cleanup, including late startup, before another job.
  Future<void> cancel();
  Future<void> dispose();
}
