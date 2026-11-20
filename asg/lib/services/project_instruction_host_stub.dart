// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project_instruction_observation.dart';
import 'project_instruction_host.dart';

ProjectInstructionHost createProjectInstructionHost() =>
    UnsupportedProjectInstructionHost();

class UnsupportedProjectInstructionHost implements ProjectInstructionHost {
  @override
  bool get supported => false;
  @override
  Future<ProjectInstructionObservation> inspect(
    ProjectInstructionReadRequest request,
  ) async => throw StateError(
    'Contained instruction document inspection is unavailable.',
  );
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
