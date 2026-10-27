// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project_inspection.dart';

class ProjectInspector {
  Future<ProjectInspection> inspect(String path) async =>
      throw UnsupportedError(
        'Project inspection requires a native filesystem.',
      );
}
