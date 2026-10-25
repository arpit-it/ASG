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

  Future<void> save(List<StudioProject> projects) async {
    if (!await records.setString(
      'studio.projects.v1',
      jsonEncode(projects.map((e) => e.toJson()).toList()),
    )) {
      throw StateError('Project records could not be saved.');
    }
  }
}
