import 'source_generation.dart';

enum ArtifactInspection {
  matching('Source and artifacts matched when inspected.'),
  missing('Recorded source or artifacts are missing.'),
  stale('Source or artifacts changed since this outcome.'),
  unverified('This outcome has no complete successful artifact evidence.'),
  unavailable('Artifact inspection is unavailable or the paths are unsafe.');

  const ArtifactInspection(this.label);
  final String label;
}

/// Optional read-only capability; inspection grants no execution authority.
abstract interface class ArtifactInspector {
  Future<ArtifactInspection> inspectArtifacts(GeneratedProject project);
}
