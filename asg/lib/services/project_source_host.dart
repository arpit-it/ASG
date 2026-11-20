// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project_source_observation.dart';

/// Owns only the trusted bounded source reader, never project commands.
abstract interface class ProjectSourceHost {
  bool get supported;
  Future<ProjectSourceObservation> inspect(ProjectSourceReadRequest request);

  /// Waits for owned cleanup, including late startup, before another job.
  Future<void> cancel();
  Future<void> dispose();
}
