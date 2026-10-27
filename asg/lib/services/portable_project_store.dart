// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/portable_project_archive.dart';
import 'record_storage.dart';
import 'studio_store.dart';

/// Refuses unknown selected metadata before projecting portable intent.
/// Identity, name and location are deliberately excluded from portable intent.
class PortableProjectStore {
  PortableProjectStore(this.records);
  final RecordStorage records;

  PortableProjectIntent? load(String id) {
    final projects = StudioStore(records)
        .load()
        .where((p) => p.id == id)
        .toList();
    if (projects.length > 1) throw StateError('Ambiguous project identity.');
    final project = projects.singleOrNull;
    if (project == null) return null;
    final rows = jsonDecode(records.getString('studio.projects.v1')!) as List;
    final row =
        rows.singleWhere((row) => row['id'] == id) as Map<String, dynamic>;
    const fields = [
      'id',
      'name',
      'description',
      'type',
      'platforms',
      'location',
    ];
    if (row.length != fields.length || !fields.every(row.containsKey)) {
      throw const FormatException('Unsupported saved project fields.');
    }
    return PortableProjectIntent(
      description: project.description,
      type: project.type,
      platforms: project.platforms,
    );
  }
}
