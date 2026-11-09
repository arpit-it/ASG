// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Identifies a retained run after preparation failed.
class SnapshotPreparationFailure implements Exception {
  const SnapshotPreparationFailure(this.runPath);

  final String runPath;
}
