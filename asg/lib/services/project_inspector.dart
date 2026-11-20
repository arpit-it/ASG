// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project_inspection.dart';
import '../models/project_metadata_observation.dart';
import 'project_metadata_host.dart';
import 'project_metadata_host_factory.dart';

/// Projects a trusted helper response. It never opens project paths itself.
class ProjectInspector {
  ProjectInspector({ProjectMetadataHost? host})
    : _host = host ?? createProjectMetadataHost();
  final ProjectMetadataHost _host;
  bool get supported => _host.supported;
  Future<ProjectInspection> inspect(
    String root, {
    required String python,
  }) async {
    if (!_host.supported) {
      throw UnsupportedError('Contained project inspection is unavailable.');
    }
    try {
      return (await _host.inspect(
        ProjectMetadataReadRequest(root: root, python: python),
      )).toInspection(root);
    } catch (_) {
      throw const FormatException('Folder metadata could not be read.');
    }
  }

  Future<void> cancel() => _host.cancel();
  Future<void> dispose() => _host.dispose();
}
