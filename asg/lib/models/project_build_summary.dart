// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'source_generation.dart';

enum ProjectBuildState {
  none,
  generated,
  unfinished,
  passed,
  failed,
  unavailable,
}

/// Saved verification evidence and input identity, not live process/disk status.
class ProjectBuildSummary {
  const ProjectBuildSummary(
    this.state, {
    this.snapshot = GeneratedSnapshotStatus.none,
  });
  final ProjectBuildState state;
  final GeneratedSnapshotStatus snapshot;
}
