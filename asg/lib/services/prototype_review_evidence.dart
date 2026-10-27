// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/project.dart';
import 'application_store.dart';
import 'project_build_summary_store.dart';
import 'record_storage.dart';

/// Read-only evidence for advisory review. Never inspects files or runs checks.
class PrototypeReviewEvidence {
  PrototypeReviewEvidence(this.records);
  final RecordStorage records;
  static const maxDefinitionCharacters = 12000;

  String load(StudioProject project) {
    final evidence = <String, Object>{
      'scope': 'Bounded prototype data and saved verification only; no new checks executed.',
    };
    try {
      final saved =
          records.getString('studio.application.v1.${project.id}') != null;
      final snapshot = ApplicationStore(records).load(project);
      final definition = snapshot.definition.toJson();
      evidence['applicationStatus'] = saved
          ? 'saved prototype'
          : 'unsaved starter fallback';
      evidence['revision'] = snapshot.revision;
      if (jsonEncode(definition).length <= maxDefinitionCharacters) {
        evidence['definition'] = definition;
      } else {
        evidence['definitionStatus'] =
            'omitted: exceeds review context limit; do not infer coverage';
      }
    } catch (_) {
      evidence['applicationStatus'] =
          'unreadable; no application evidence available';
    }
    final build = ProjectBuildSummaryStore(records).load(project);
    evidence['savedBuildState'] = build.state.name;
    evidence['savedBuildInputMatch'] = build.snapshot.name;
    evidence['buildLimits'] = 'Historical saved evidence; no current filesystem, artifact, process or runtime verification.';
    return jsonEncode(evidence);
  }
}
