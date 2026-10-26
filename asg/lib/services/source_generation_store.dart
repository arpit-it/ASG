import 'dart:convert';

import '../models/build_history_entry.dart';
import '../models/source_generation.dart';
import 'record_storage.dart';

class SourceGenerationStore {
  SourceGenerationStore(this.records, {this.prefix = 'studio.generation.v1.'});
  final String prefix;
  final RecordStorage records;

  Map<String, dynamic>? _record(String id) {
    final raw = records.getString('$prefix$id');
    return raw == null
        ? null
        : Map<String, dynamic>.from(jsonDecode(raw) as Map);
  }

  GeneratedProject? load(String id) {
    final json = _record(id);
    if (json == null) return null;
    // Corruption must block writes and execution, not disappear.
    parseHistory(json);
    return GeneratedProject.fromJson(json);
  }

  static List<BuildHistoryEntry> parseHistory(Map<String, dynamic> json) {
    if (!json.containsKey('buildHistory') &&
        !json.containsKey('buildHistoryVersion')) {
      return const [];
    }
    if (json['buildHistoryVersion'] != 1 || json['buildHistory'] is! List) {
      throw const FormatException('Unsupported build history.');
    }
    return List.unmodifiable(
      (json['buildHistory'] as List).map(
        (entry) =>
            BuildHistoryEntry.fromJson(Map<String, dynamic>.from(entry as Map)),
      ),
    );
  }

  List<BuildHistoryEntry> history(String id) {
    final json = _record(id);
    return json == null ? const [] : parseHistory(json);
  }

  /// Current outcome and journal share one durable record/publication point.
  /// Promotion uses this same encoding in its conditional transaction.
  String encodeUpdate(String id, GeneratedProject project) {
    GeneratedProject.fromJson(project.toJson());
    final previous = _record(id);
    final entries = previous == null
        ? <BuildHistoryEntry>[]
        : [...parseHistory(previous)];
    if (previous != null) {
      final legacy = GeneratedProject.fromJson(previous);
      if (!previous.containsKey('buildHistory') &&
          (legacy.phase == SourceGenerationPhase.ready ||
              legacy.phase == SourceGenerationPhase.failed)) {
        entries.add(BuildHistoryEntry(recordedAt: null, project: legacy));
      }
    }
    final terminal =
        project.phase == SourceGenerationPhase.ready ||
        project.phase == SourceGenerationPhase.failed;
    if (terminal &&
        (entries.isEmpty ||
            previous?['phase'] == SourceGenerationPhase.verifying.name ||
            jsonEncode(entries.last.project.toJson()) !=
                jsonEncode(project.toJson()))) {
      entries.add(
        BuildHistoryEntry(recordedAt: DateTime.now().toUtc(), project: project),
      );
    }
    return jsonEncode({
      ...project.toJson(),
      'buildHistoryVersion': 1,
      'buildHistory': entries.map((entry) => entry.toJson()).toList(),
    });
  }

  Future<void> save(String id, GeneratedProject project) async {
    final value = encodeUpdate(id, project);
    if (!await records.setString('$prefix$id', value)) {
      throw StateError('Generation outcome could not be saved.');
    }
  }
}
