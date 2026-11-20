// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project_inspection.dart';

class ProjectInspector {
  bool get supported => false;
  Future<ProjectInspection> inspect(
    String root, {
    required String python,
  }) async =>
      throw UnsupportedError('Contained project inspection is unavailable.');
  Future<void> cancel() async {}
  Future<void> dispose() async {}
}
