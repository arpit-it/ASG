// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project_source_observation.dart';
import 'project_source_host.dart';

ProjectSourceHost createProjectSourceHost() => UnsupportedProjectSourceHost();

class UnsupportedProjectSourceHost implements ProjectSourceHost {
  @override
  bool get supported => false;
  @override
  Future<ProjectSourceObservation> inspect(
    ProjectSourceReadRequest request,
  ) async =>
      throw StateError('Contained source file inspection is unavailable.');
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
