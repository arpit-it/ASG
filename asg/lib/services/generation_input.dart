import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/app_definition.dart';
import '../models/project.dart';
import '../models/source_generation.dart';

/// The original v1 data payloads shared by export and snapshot comparison.
/// Keep their serialization stable so existing generated records remain useful.
class GenerationInput {
  GenerationInput(StudioProject project, AppDefinition definition)
    : applicationJson = jsonEncode(
        AppDefinition.fromJson(definition.toJson()).toJson(),
      ),
      metadataJson = jsonEncode({
        'schema': 1,
        'generator': 'asg-flutter-web-v1',
        'requirements': project.toJson(),
        'definition': definition.toJson(),
      });

  final String applicationJson, metadataJson;
  late final Map<String, String> fingerprints = Map.unmodifiable({
    'assets/app.json': sha256.convert(utf8.encode(applicationJson)).toString(),
    'asg_project.json': sha256.convert(utf8.encode(metadataJson)).toString(),
  });

  GeneratedSnapshotStatus compare(GeneratedProject? project) {
    if (project == null) return GeneratedSnapshotStatus.none;
    final expected = fingerprints;
    if (expected.keys.any((key) => !project.sources.containsKey(key))) {
      return GeneratedSnapshotStatus.unknown;
    }
    return expected.entries.every(
          (entry) => project.sources[entry.key] == entry.value,
        )
        ? GeneratedSnapshotStatus.current
        : GeneratedSnapshotStatus.outdated;
  }
}
