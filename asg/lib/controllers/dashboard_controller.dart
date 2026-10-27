import '../models/project.dart';
import '../models/project_build_summary.dart';
import '../services/project_build_summary_store.dart';
import '../services/studio_store.dart';
import 'base_controller.dart';

class DashboardController extends BaseController {
  DashboardController(
    this.store,
    List<StudioProject> initial, {
    ProjectBuildSummaryStore? summaries,
  }) : _projects = List.of(initial),
       _summaries = summaries ?? ProjectBuildSummaryStore(store.records);
  final ProjectBuildSummaryStore _summaries;
  ProjectBuildSummary buildSummary(StudioProject project) =>
      _summaries.load(project);
  final StudioStore store;
  List<StudioProject> _projects;
  String _query = '';
  bool busy = false;
  String? error;
  List<StudioProject> get projects => List.unmodifiable(_projects);
  List<StudioProject> get filtered => _projects
      .where((p) => p.name.toLowerCase().contains(_query.toLowerCase()))
      .toList();
  void refreshBuildStatus() => update();

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
    } catch (_) {
      if (isDisposed) return false;
      error = 'Could not save project. Check local storage and retry. Your saved projects have not been changed.';
      return false;
    } finally {
      busy = false;
      update();
    }
  }
}
