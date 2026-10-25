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
  String? _error;
  String? get error => _error;
  Future<bool> create(StudioProject project) async {
    if (_busy || isDisposed) return false;
    _busy = true;
    _error = null;
    update();
    try {
      await store.projects.save([...store.load(), project]);
      if (isDisposed) return false;
      await store.select(project.id);
      if (isDisposed) return false;
      _current = project;
      return true;
    } catch (e) {
      if (!isDisposed) _error = 'Project could not be opened: $e';
      return false;
    } finally {
      _busy = false;
      update();
    }
  }

  void refreshCurrent() {
    if (_busy || isDisposed || _current == null) return;
    try {
      _current = store.load().where((p) => p.id == _current!.id).single;
      _error = null;
    } catch (e) {
      _error = 'Project details could not be refreshed: $e';
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
      if (!isDisposed) _current = project;
    } catch (e) {
      if (!isDisposed) _error = 'Project could not be opened: $e';
    } finally {
      _busy = false;
      update();
    }
  }
}
