import '../models/artifact_inspection.dart';
import '../models/source_generation.dart';
import 'generation_host.dart';
import 'generation_host_factory.dart';

/// Owns a read-only host session, created only for an explicit inspection.
class RequirementArtifactInspector implements ArtifactInspector {
  RequirementArtifactInspector({this.createHost = createGenerationHost});
  final GenerationHost Function() createHost;

  @override
  Future<ArtifactInspection> inspectArtifacts(GeneratedProject project) async {
    final host = createHost();
    try {
      return host is ArtifactInspector
          ? await (host as ArtifactInspector).inspectArtifacts(project)
          : ArtifactInspection.unavailable;
    } finally {
      await host.dispose();
    }
  }
}
