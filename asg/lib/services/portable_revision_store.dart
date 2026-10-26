import 'dart:convert';

import '../models/portable_project_archive.dart';
import '../models/source_generation.dart';
import '../models/structured_proposal_json.dart';
import 'record_storage.dart';
import 'source_generation_store.dart';

/// Imported summaries never enter the executable generation or rollback stores.
class PortableRevisionStore {
  PortableRevisionStore(this.records);
  final RecordStorage records;
  static String key(String id) => 'studio.historicalRevisions.v1.$id';
  static List<PortableRevisionSummary> decode(String raw) {
    if (raw.length > PortableProjectArchive.maxBytes ||
        utf8.encode(raw).length > PortableProjectArchive.maxBytes) {
      throw const FormatException('Historical revisions exceed archive limit.');
    }
    rejectDuplicateJsonMembers(raw);
    return PortableRevisionSummary.parseList(jsonDecode(raw));
  }

  List<PortableRevisionSummary> load(String id) {
    final raw = records.getString(key(id));
    final imported = raw == null ? <PortableRevisionSummary>[] : decode(raw);
    final generation = records.getString('studio.generation.v1.$id');
    if (generation != null) _validateGeneration(jsonDecode(generation));
    final store = SourceGenerationStore(records);
    // Validate even a journal-free legacy record.
    final current = store.load(id);
    final history = store.history(id);
    final local = history.map(
      (entry) => summarize(entry.project, entry.recordedAt),
    );
    final result = [...imported, ...local];
    if (history.isEmpty &&
        current != null &&
        (current.phase == SourceGenerationPhase.ready ||
            current.phase == SourceGenerationPhase.failed)) {
      result.add(summarize(current, null));
    }
    if (result.length > 1000) {
      throw const FormatException('Too many historical revision summaries.');
    }
    return List.unmodifiable(result);
  }

  // Validate fields before normal decoders deliberately select known data.
  // This export-only check does not change normal history or execution decoding.
  static void _validateGeneration(Object? value, {bool journal = true}) {
    const fields = {
      'limits',
      'confinementVersion',
      'directory',
      'sdk',
      'python',
      'sources',
      'outputs',
      'resolution',
      'steps',
      'phase',
      'error',
      'failedOperation',
      'pendingOperation',
      'checkpointVersion',
      'approval',
      'tasks',
    };
    if (value is! Map<String, dynamic> ||
        value.keys.any(
          (key) =>
              !fields.contains(key) &&
              !(journal &&
                  const {'buildHistoryVersion', 'buildHistory'}.contains(key)),
        )) {
      throw const FormatException('Unsupported saved generation fields.');
    }
    if (!value.containsKey('buildHistory')) return;
    final entries = value['buildHistory'];
    if (entries is! List) {
      throw const FormatException('Malformed saved build history.');
    }
    for (final entry in entries) {
      if (entry is! Map<String, dynamic> ||
          entry.length != 2 ||
          !entry.containsKey('recordedAt') ||
          !entry.containsKey('project')) {
        throw const FormatException('Unsupported saved build history fields.');
      }
      _validateGeneration(entry['project'], journal: false);
    }
  }

  static PortableRevisionSummary summarize(
    GeneratedProject project,
    DateTime? at,
  ) {
    int? requirementsRevision, prototypeRevision;
    final context = project.approval?.context;
    if (context != null && context.trimLeft().startsWith('{')) {
      rejectDuplicateJsonMembers(context);
      final value = jsonDecode(context);
      if (value is Map &&
          (value.containsKey('requirementsRevision') ||
              value.containsKey('prototypeRevision'))) {
        if (value['requirementsRevision'] is! int ||
            value['prototypeRevision'] is! int) {
          throw const FormatException('Invalid historical input revisions.');
        }
        requirementsRevision = value['requirementsRevision'] as int;
        prototypeRevision = value['prototypeRevision'] as int;
      }
    }
    return PortableRevisionSummary(
      requirementsRevision: requirementsRevision,
      prototypeRevision: prototypeRevision,
      recordedAt: at,
      outcome: project.phase.name,
      passedChecks: project.steps.where((step) => step.succeeded).length,
      totalChecks: project.steps.length,
    );
  }
}
