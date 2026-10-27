// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/project_build_summary.dart';
import '../models/source_generation.dart';

class ProjectBuildStatusView extends StatelessWidget {
  const ProjectBuildStatusView({super.key, required this.summary});
  final ProjectBuildSummary summary;

  @override
  Widget build(BuildContext context) {
    final status = switch (summary.state) {
      ProjectBuildState.none => 'No source snapshot yet',
      ProjectBuildState.generated => 'Saved source · not verified',
      ProjectBuildState.unfinished => 'Saved verification incomplete',
      ProjectBuildState.passed => 'Saved web verification passed',
      ProjectBuildState.failed => 'Saved generation/verification failed',
      ProjectBuildState.unavailable => 'Saved build history unreadable',
    };
    final inputs = switch (summary.snapshot) {
      GeneratedSnapshotStatus.none => null,
      GeneratedSnapshotStatus.current => 'Matches current app and requirements',
      GeneratedSnapshotStatus.outdated => 'Earlier app or requirements',
      GeneratedSnapshotStatus.unknown => 'Input match unavailable',
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [Text(status), if (inputs != null) Text(inputs)],
    );
  }
}
