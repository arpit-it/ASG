import '../models/project_inspection.dart';

class ProjectInspector {
  Future<ProjectInspection> inspect(String path) async =>
      throw UnsupportedError(
        'Project inspection requires a native filesystem.',
      );
}
