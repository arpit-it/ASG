import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/project.dart';

class StudioStore {
  StudioStore(this.preferences);
  final SharedPreferences preferences;
  List<StudioProject> load() {
    final raw = preferences.getString('studio.projects.v1');
    if (raw == null) return [];
    return (jsonDecode(raw) as List)
        .map((e) => StudioProject.fromJson(Map<String, dynamic>.from(e as Map)))
        .toList();
  }

  Future<void> save(List<StudioProject> projects) async {
    if (!await preferences.setString(
      'studio.projects.v1',
      jsonEncode(projects.map((e) => e.toJson()).toList()),
    )) {
      throw StateError('Project records could not be saved.');
    }
  }
}
