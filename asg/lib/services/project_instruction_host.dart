// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project_instruction_observation.dart';

/// Owns only the trusted bounded metadata helper, never project commands.
abstract interface class ProjectInstructionHost {
  bool get supported;
  Future<ProjectInstructionObservation> inspect(
    ProjectInstructionReadRequest request,
  );

  /// Waits for owned cleanup, including late startup, before another job.
  Future<void> cancel();
  Future<void> dispose();
}
