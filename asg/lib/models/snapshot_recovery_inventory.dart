// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// The displayed recovery paths and the remaining matches in a complete scan.
class SnapshotRecoveryInventory {
  SnapshotRecoveryInventory({
    required Iterable<String> paths,
    required this.additionalCount,
  }) : paths = List.unmodifiable(paths);

  final List<String> paths;
  final int additionalCount;
}
