// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project.dart';
import '../models/project_build_summary.dart';
import '../models/source_generation.dart';
import 'application_store.dart';
import 'generation_input.dart';
import 'record_storage.dart';
import 'source_generation_store.dart';

class ProjectBuildSummaryStore {
  ProjectBuildSummaryStore(this.records);
  final RecordStorage records;

  ProjectBuildSummary load(StudioProject project) {
    final GeneratedProject? saved;
    try {
      saved = SourceGenerationStore(records).load(project.id);
    } catch (_) {
      return const ProjectBuildSummary(ProjectBuildState.unavailable);
    }
    if (saved == null) return const ProjectBuildSummary(ProjectBuildState.none);
    var snapshot = GeneratedSnapshotStatus.unknown;
    try {
      snapshot = GenerationInput(
        project,
        ApplicationStore(records).load(project).definition,
      ).compare(saved);
    } catch (_) {
      // A broken application record must not hide saved build evidence or
      // prevent opening another project. No fallback record is written.
    }
    return ProjectBuildSummary(switch (saved.phase) {
      SourceGenerationPhase.generated => ProjectBuildState.generated,
      SourceGenerationPhase.verifying => ProjectBuildState.unfinished,
      SourceGenerationPhase.ready => ProjectBuildState.passed,
      SourceGenerationPhase.failed => ProjectBuildState.failed,
    }, snapshot: snapshot);
  }
}
