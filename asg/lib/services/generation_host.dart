import '../models/app_definition.dart';
import '../models/project.dart';
import '../models/source_generation.dart';

typedef GenerationProgress = Future<void> Function(GeneratedProject project);

abstract interface class GenerationHost {
  bool get supported;
  Future<GeneratedProject> generate({
    required StudioProject project,
    required AppDefinition definition,
    required String parent,
    required String name,
    required String sdk,
    required String python,
  });
  Future<GeneratedProject> verify(
    GeneratedProject project,
    GenerationProgress progress,
  );
  Future<Uri> startPreview(GeneratedProject project);
  Future<void> openPreview(Uri uri);
  Future<void> stopPreview();
  Future<void> dispose();
}
