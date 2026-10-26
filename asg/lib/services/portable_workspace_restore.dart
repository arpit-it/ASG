import 'dart:convert';

import '../models/portable_project_archive.dart';
import '../models/project.dart';
import 'portable_archive_store.dart';
import 'portable_decision_store.dart';
import 'portable_revision_store.dart';
import 'record_storage.dart';
import 'studio_store.dart';

/// Publishes supported portable records as a new app workspace in one commit.
/// No source, execution evidence, settings or approval is restored.
class PortableWorkspaceRestore {
  PortableWorkspaceRestore(this.records);
  final ConditionalRecordStorage records;

  Future<StudioProject> restore({
    required String id,
    required String name,
    required String encoded,
  }) async {
    PortableArchiveStore.key(id); // Reuse the bounded, path-free ID contract.
    if (StudioProject.validateName(name) != null || name.length > 200) {
      throw const FormatException(
        'Enter a project name of up to 200 characters.',
      );
    }
    final archive = PortableProjectArchive.decode(encoded);
    const catalogKey = 'studio.projects.v1';
    final catalog = records.getString(catalogKey);
    final projects = StudioStore(records).load(); // Corruption fails closed.
    final ids = <String>{};
    for (final project in projects) {
      if (!ids.add(project.id) || project.id == id) {
        throw StateError(
          'Project identity exists or the catalog is ambiguous.',
        );
      }
    }
    final expected = <String, String?>{catalogKey: catalog};
    for (final namespace in const [
      'application',
      'chat',
      'requirements',
      'planApproval',
      'historicalDecision',
      'historicalRevisions',
      'generation',
      'generationPrevious',
      'sourceCandidate',
      'candidateChecks',
      'repairAttempts',
    ]) {
      final key = 'studio.$namespace.v1.$id';
      if (records.getString(key) != null) {
        throw StateError('Project records already exist. Choose a new ID.');
      }
      expected[key] = null;
    }
    final project = StudioProject(
      id: id,
      name: name.trim(),
      description:
          'Restored portable requirements and assistance conversation. '
          'Prototype and source are not part of this archive.',
      type: 'Flutter',
      platforms: const ['Web'],
      location: '',
    );
    final updates = <String, String>{
      if (archive.revisions.isNotEmpty)
        PortableRevisionStore.key(id): jsonEncode(
          archive.revisions.map((r) => r.toJson()).toList(),
        ),
      if (archive.decision case final decision?)
        PortableDecisionStore.key(id): jsonEncode(decision.toJson()),
      catalogKey: jsonEncode(
        [...projects, project].map((p) => p.toJson()).toList(),
      ),
      'studio.chat.v1.$id': jsonEncode(
        archive.messages.map((m) => m.toJson()).toList(),
      ),
      // An empty revision-zero board is represented by an absent record.
      if (archive.requirements.revision > 0)
        'studio.requirements.v1.$id': jsonEncode(archive.requirements.toJson()),
    };
    await records.commitRecords(
      expected: expected,
      updates: updates,
      authorize: () {},
    );
    return project;
  }
}
