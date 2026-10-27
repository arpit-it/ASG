import '../models/project.dart';
import '../services/studio_session_store.dart';
import 'base_controller.dart';

class StudioSessionController extends BaseController {
  StudioSessionController(this.store, List<StudioProject> initial) {
    for (final p in initial) {
      if (p.id == store.lastProject) _current = p;
    }
    _current ??= initial.lastOrNull;
  }
  final StudioSessionStore store;
  StudioProject? _current;
  StudioProject? get current => _current;
  bool _busy = false;
  bool get busy => _busy;
  StudioProject? _savedCreation;
  StudioProject? get savedCreation => _savedCreation;
  String? _error;
  String? get error => _error;
  Future<bool> create(StudioProject project) async {
    if (_busy || isDisposed || _savedCreation != null) return false;
    _busy = true;
    _error = null;
    update();
    try {
      final projects = store.load();
      if (projects.any((saved) => saved.id == project.id)) {
        _error = 'Project identity already exists. Open it from Projects.';
        return false;
      }
      await store.projects.save([...projects, project]);
      if (isDisposed) return false;
      _savedCreation = project;
      await store.select(project.id);
      if (isDisposed) return false;
      _savedCreation = null;
      _current = project;
      return true;
    } catch (_) {
      if (!isDisposed) {
        _error = _savedCreation == null
            ? 'Project could not be created. Check local storage and retry.'
            : 'Project was saved but could not be opened. Check local storage, then retry opening it or find it in Projects.';
      }
      return false;
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> retrySavedCreation() async {
    final saved = _savedCreation;
    if (saved == null || _busy || isDisposed) return;
    // Reread metadata: another editor may have changed the saved project.
    try {
      final project = store.load().where((p) => p.id == saved.id).single;
      await select(project);
    } catch (_) {
      _error = 'Saved project could not be reopened. Check Projects and local storage, then retry opening it.';
      update();
    }
  }

  void refreshCurrent() {
    if (_busy || isDisposed || _current == null) return;
    try {
      _current = store.load().where((p) => p.id == _current!.id).single;
      _error = null;
    } catch (_) {
      _error = 'Project details could not be refreshed. Check local storage and retry.';
    }
    update();
  }

  Future<void> select(StudioProject project) async {
    if (_busy || isDisposed) return;
    _busy = true;
    _error = null;
    update();
    try {
      await store.select(project.id);
      if (!isDisposed) {
        _current = project;
        _savedCreation = null;
      }
    } catch (_) {
      if (!isDisposed) _error = 'Project could not be opened. Check local storage and retry from Projects.';
    } finally {
      _busy = false;
      update();
    }
  }
}
