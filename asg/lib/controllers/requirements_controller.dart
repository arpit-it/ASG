import '../models/requirements_board.dart';
import '../services/requirements_store.dart';
import 'base_controller.dart';

class RequirementsController extends BaseController {
  RequirementsController(this.projectId, this.store);
  final String projectId;
  final RequirementsStore store;
  RequirementsBoard? _board;
  RequirementsBoard? get board => _board;
  bool _busy = false;
  bool get busy => _busy;
  String? _error;
  String? get error => _error;
  void load() {
    if (busy || isDisposed) return;
    try {
      _board = store.load(projectId);
      _error = null;
    } catch (e) {
      _board = null;
      _error = '$e';
    }
    update();
  }

  Future<bool> _save(RequirementsBoard draft) async {
    if (busy || isDisposed || _board == null) return false;
    _busy = true;
    _error = null;
    update();
    try {
      final saved = await store.save(projectId, _board!, draft);
      if (isDisposed) return false;
      _board = saved;
      return true;
    } catch (e) {
      if (!isDisposed) _error = '$e';
      return false;
    } finally {
      _busy = false;
      update();
    }
  }

  // Reopening or changing a prerequisite reopens every dependent, transitively.
  List<DevelopmentTask> _reopen(
    List<DevelopmentTask> tasks,
    Set<String> affected,
  ) {
    bool changed;
    do {
      changed = false;
      for (final t in tasks) {
        if (!affected.contains(t.id) && t.dependencies.any(affected.contains)) {
          affected.add(t.id);
          changed = true;
        }
      }
    } while (changed);
    return [
      for (final t in tasks)
        affected.contains(t.id) ? t.withStatus(TaskStatus.queued) : t,
    ];
  }

  Future<bool> saveRequirement(
    ProjectRequirement requirement, {
    bool editing = false,
  }) async {
    if (busy || isDisposed) return false;
    final current = _board;
    if (current == null) return false;
    if (!editing && current.requirements.any((r) => r.id == requirement.id)) {
      _error = 'Requirement ID already exists. Use Edit to change it.';
      update();
      return false;
    }
    final affected = current.tasks
        .where((t) => t.requirementId == requirement.id)
        .map((t) => t.id)
        .toSet();
    return _save(
      RequirementsBoard(
        requirements: [
          for (final r in current.requirements)
            if (r.id != requirement.id) r,
          requirement,
        ],
        tasks: _reopen(current.tasks, affected),
      ),
    );
  }

  Future<bool> saveTask(DevelopmentTask task, {bool editing = false}) async {
    if (busy || isDisposed) return false;
    final current = _board;
    if (current == null) return false;
    if (!editing && current.tasks.any((t) => t.id == task.id)) {
      _error = 'Task ID already exists. Use Edit to change it.';
      update();
      return false;
    }
    final previous = current.tasks.where((t) => t.id == task.id).firstOrNull;
    final tasks = [
      for (final t in current.tasks)
        if (t.id != task.id) t,
      task,
    ];
    final scopeChanged =
        previous != null &&
        (previous.requirementId != task.requirementId ||
            previous.title != task.title ||
            previous.dependencies.join(',') != task.dependencies.join(','));
    return _save(
      RequirementsBoard(
        requirements: current.requirements,
        tasks: task.status == TaskStatus.queued || scopeChanged
            ? _reopen(tasks, {task.id})
            : tasks,
      ),
    );
  }
}
