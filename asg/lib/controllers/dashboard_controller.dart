import '../models/project.dart';
import '../services/studio_store.dart';
import 'base_controller.dart';

class DashboardController extends BaseController {
  DashboardController(this.store, List<StudioProject> initial)
    : _projects = List.of(initial);
  final StudioStore store;
  List<StudioProject> _projects;
  String _query = '';
  bool busy = false;
  String? error;
  List<StudioProject> get projects => List.unmodifiable(_projects);
  List<StudioProject> get filtered => _projects
      .where((p) => p.name.toLowerCase().contains(_query.toLowerCase()))
      .toList();
  void search(String value) {
    _query = value;
    update();
  }

  Future<bool> add(StudioProject project) async {
    if (busy || isDisposed) return false;
    busy = true;
    error = null;
    update();
    try {
      final updated = [..._projects, project];
      await store.save(updated);
      if (isDisposed) return false;
      _projects = updated;
      return true;
    } catch (e) {
      error = 'Could not save project: $e';
      return false;
    } finally {
      busy = false;
      update();
    }
  }
}
