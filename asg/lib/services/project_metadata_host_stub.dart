// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project_metadata_observation.dart';
import 'project_metadata_host.dart';

ProjectMetadataHost createProjectMetadataHost() =>
    UnsupportedProjectMetadataHost();

class UnsupportedProjectMetadataHost implements ProjectMetadataHost {
  @override
  bool get supported => false;
  @override
  Future<ProjectMetadataObservation> inspect(
    ProjectMetadataReadRequest request,
  ) async =>
      throw StateError('Contained project metadata inspection is unavailable.');
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
