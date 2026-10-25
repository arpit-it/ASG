import '../models/source_generation.dart';

/// Source inspection requires a native filesystem. It never grants execution.
Future<Map<String, String>> readSourceReviewSnapshot(
  GeneratedProject project,
  List<String> selectedPaths,
) async =>
    throw UnsupportedError('Source review requires a native filesystem.');
