import '../models/project.dart';
import '../services/project_details_store.dart';
import 'base_controller.dart';

class ProjectDetailsController extends BaseController {
  ProjectDetailsController(StudioProject project, this.store)
    : _project = project;
  StudioProject _project;
  StudioProject get project => _project;
  final ProjectDetailsStore store;
  bool _busy = false;
  bool get busy => _busy;
  String? _error;
  String? get error => _error;

  Future<bool> save(String name, String description) async {
    if (_busy || isDisposed) return false;
    _error = StudioProject.validateName(name);
    if (_error == null && description.trim().isEmpty) {
      _error = 'Describe what this project should create.';
    }
    if (_error != null) {
      update();
      return false;
    }
    _busy = true;
    update();
    try {
      await store.preserveApplication(project);
      if (isDisposed) return false;
      final updated = await store.update(
        project,
        name.trim(),
        description.trim(),
      );
      if (isDisposed) return false;
      _project = updated;
      return true;
    } catch (_) {
      if (!isDisposed) {
        _error =
            'Project details could not be saved. Check local storage and retry. '
            'Reopen the project details if the saved project has changed.';
      }
      return false;
    } finally {
      _busy = false;
      update();
    }
  }
}
