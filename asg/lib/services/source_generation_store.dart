import 'dart:convert';

import '../models/source_generation.dart';
import 'record_storage.dart';

class SourceGenerationStore {
  SourceGenerationStore(this.records);
  final RecordStorage records;
  GeneratedProject? load(String id) {
    final raw = records.getString('studio.generation.v1.$id');
    return raw == null
        ? null
        : GeneratedProject.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(String id, GeneratedProject project) async {
    if (!await records.setString(
      'studio.generation.v1.$id',
      jsonEncode(project.toJson()),
    )) {
      throw StateError('Generation outcome could not be saved.');
    }
  }
}
