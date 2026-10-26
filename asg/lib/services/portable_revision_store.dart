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

  static PortableRevisionSummary summarize(
    GeneratedProject project,
    DateTime? at,
  ) => PortableRevisionSummary(
    recordedAt: at,
    outcome: project.phase.name,
    passedChecks: project.steps.where((step) => step.succeeded).length,
    totalChecks: project.steps.length,
  );
}
