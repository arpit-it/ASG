import 'dart:convert';

import '../models/project.dart';
import 'application_store.dart';
import 'studio_store.dart';

/// Updates metadata without deriving a new application from changed requirements.
class ProjectDetailsStore {
  ProjectDetailsStore(this.projects);
  final StudioStore projects;

  List<StudioProject> _currentRecords(StudioProject original) {
    final all = projects.load();
    final matches = all.where((p) => p.id == original.id).toList();
    if (matches.length != 1 ||
        jsonEncode(matches.single.toJson()) != jsonEncode(original.toJson())) {
      throw StateError(
        'Project changed or is unavailable. Reopen its details.',
      );
    }
    return all;
  }

  Future<void> preserveApplication(StudioProject original) async {
    _currentRecords(original);
    final applications = ApplicationStore(projects.records);
    // A never-edited starter exists only in memory. Freeze it before changing
    // its metadata inputs, so reopening cannot silently create a different app.
    if (projects.records.getString('studio.application.v1.${original.id}') ==
        null) {
      await applications.save(original.id, applications.load(original));
    } else {
      applications.load(original); // Refuse corrupt application records.
    }
  }

  Future<StudioProject> update(
    StudioProject original,
    String name,
    String description,
  ) async {
    final all = _currentRecords(original);
    final updated = StudioProject(
      id: original.id,
      name: name,
      description: description,
      type: original.type,
      platforms: List.unmodifiable(original.platforms),
      location: original.location,
    );
    await projects.save([
      for (final project in all) project.id == original.id ? updated : project,
    ]);
    return updated;
  }
}
