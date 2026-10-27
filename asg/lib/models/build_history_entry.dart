// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'source_generation.dart';

/// Recorded evidence only; artifact existence requires a live inspection or preview check.
class BuildHistoryEntry {
  const BuildHistoryEntry({required this.recordedAt, required this.project});
  final DateTime? recordedAt;
  final GeneratedProject project;

  Map<String, Object?> toJson() => {
    'recordedAt': recordedAt?.toUtc().toIso8601String(),
    'project': project.toJson(),
  };

  factory BuildHistoryEntry.fromJson(Map<String, dynamic> json) {
    final project = GeneratedProject.fromJson(
      Map<String, dynamic>.from(json['project'] as Map),
    );
    if (project.phase != SourceGenerationPhase.ready &&
        project.phase != SourceGenerationPhase.failed) {
      throw const FormatException('History requires a terminal outcome.');
    }
    return BuildHistoryEntry(
      recordedAt: json['recordedAt'] == null
          ? null
          : DateTime.parse(json['recordedAt'] as String).toUtc(),
      project: project,
    );
  }
}
