// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'record_storage.dart';

import '../models/project.dart';

class StudioStore {
  StudioStore(this.records);
  StudioStore.fromPreferences(SharedPreferences preferences)
    : this(PreferenceRecords(preferences));
  final RecordStorage records;
  List<StudioProject> load() {
    final raw = records.getString('studio.projects.v1');
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((e) => StudioProject.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  /// Append to the current durable list, refusing concurrent replacement.
  Future<List<StudioProject>> append(StudioProject project) async {
    const key = 'studio.projects.v1';
    final before = records.getString(key);
    final current = load();
    if (current.any((saved) => saved.id == project.id)) {
      throw StateError('Project identity already exists.');
    }
    final updated = [...current, project];
    final storage = records;
    if (storage is ConditionalRecordStorage) {
      await storage.commitRecords(
        expected: {key: before},
        updates: {key: jsonEncode(updated.map((p) => p.toJson()).toList())},
        authorize: () {},
      );
    } else {
      await save(updated);
    }
    return updated;
  }

  Future<void> save(List<StudioProject> projects) async {
    if (!await records.setString(
      'studio.projects.v1',
      jsonEncode(projects.map((e) => e.toJson()).toList()),
    )) {
      throw StateError('Project records could not be saved.');
    }
  }
}
