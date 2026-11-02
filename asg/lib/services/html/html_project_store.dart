// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../../models/project.dart';
import '../../models/html/saved_html_starter.dart';
import '../record_storage.dart';
import '../studio_store.dart';
import 'html_starter_store.dart';

/// Registration remembers original inputs; it grants no execution authority.
class HtmlProjectStore {
  HtmlProjectStore(this.records);
  final RecordStorage records;
  static const projectsKey = 'studio.projects.v1';

  SavedHtmlStarter resolve(StudioProject project) {
    final canonical = StudioStore(records)
        .load()
        .where((p) => p.id == project.id)
        .single;
    if (canonical.type != 'HTML' || canonical.location != project.location) {
      throw StateError('HTML project identity changed.');
    }
    return HtmlStarterStore(records)
        .load()
        .where((s) => s.directory == canonical.location)
        .single;
  }

  Future<StudioProject> register(
    SavedHtmlStarter starter, {
    required void Function() authorize,
  }) async {
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw UnsupportedError(
        'HTML registration requires transactional storage.',
      );
    }
    final beforeProjects = storage.getString(projectsKey);
    final beforeStarters = storage.getString(HtmlStarterStore.key);
    final projects = StudioStore(storage).load();
    final starters = HtmlStarterStore(storage).load();
    if (projects.map((p) => p.id).toSet().length != projects.length) {
      throw StateError('Ambiguous project identities.');
    }
    final matchingStarters = starters.where(
      (s) => s.directory == starter.directory,
    );
    if (matchingStarters.isNotEmpty &&
        jsonEncode(matchingStarters.single.toJson()) !=
            jsonEncode(starter.toJson())) {
      throw StateError('Different original starter inputs already exist.');
    }
    final matchingProjects = projects
        .where((p) => p.location == starter.directory)
        .toList();
    if (matchingProjects.length > 1 ||
        (matchingProjects.isNotEmpty &&
            matchingProjects.single.type != 'HTML')) {
      throw StateError('Destination already belongs to another project.');
    }
    if (matchingProjects.isNotEmpty) {
      if (matchingStarters.isEmpty) {
        throw StateError('Original starter record is missing.');
      }
      authorize();
      return matchingProjects.single;
    }
    if (matchingStarters.isEmpty && starters.length >= 100) {
      throw StateError('Starter library is full.');
    }
    final project = StudioProject(
      id: 'html-${DateTime.now().microsecondsSinceEpoch}',
      name: starter.input.title,
      description: starter.input.description,
      type: 'HTML',
      platforms: const ['Web'],
      location: starter.directory,
    );
    if (projects.any((p) => p.id == project.id)) {
      throw StateError('Project identity conflict.');
    }
    authorize();
    await storage.commitRecords(
      expected: {
        projectsKey: beforeProjects,
        HtmlStarterStore.key: beforeStarters,
      },
      updates: {
        projectsKey: jsonEncode(
          [...projects, project].map((p) => p.toJson()).toList(),
        ),
        HtmlStarterStore.key: jsonEncode(
          [
            ...starters,
            if (matchingStarters.isEmpty) starter,
          ].map((s) => s.toJson()).toList(),
        ),
      },
      authorize: authorize,
    );
    return project;
  }
}
