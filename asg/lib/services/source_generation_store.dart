import 'dart:convert';

import '../models/source_generation.dart';
import 'record_storage.dart';

class SourceGenerationStore {
  SourceGenerationStore(this.records, {this.prefix = 'studio.generation.v1.'});
  final String prefix;
  final RecordStorage records;
  GeneratedProject? load(String id) {
    final raw = records.getString('$prefix$id');
    return raw == null
        ? null
        : GeneratedProject.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(String id, GeneratedProject project) async {
    if (!await records.setString('$prefix$id', jsonEncode(project.toJson()))) {
      throw StateError('Generation outcome could not be saved.');
    }
  }
}
