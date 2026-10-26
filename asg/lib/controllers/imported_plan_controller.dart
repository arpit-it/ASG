import '../models/imported_plan.dart';
import '../models/project_inspection.dart';
import '../services/imported_plan_store.dart';
import '../services/project_inspector.dart';
import 'base_controller.dart';

class ImportedPlanController extends BaseController {
  ImportedPlanController(
    this.root,
    this.store, {
    Future<ProjectInspection> Function(String)? inspect,
  }) : _inspect = inspect ?? ProjectInspector().inspect;
  final String root;
  final ImportedPlanStore store;
  final Future<ProjectInspection> Function(String) _inspect;
  ImportedPlan? plan;
  String? error;
  String? _context;
  ProjectInspection? _inspection;
  bool busy = false;
  bool get current {
    try {
      return _inspection != null &&
          _context != null &&
          plan != null &&
          plan!.context == store.context(_inspection!);
    } catch (_) {
      return false;
    }
  }

  bool get approved => current && plan!.approved;
  Future<void> load() async {
    if (isDisposed || busy) return;
    busy = true;
    error = null;
    _context = null;
    update();
    try {
      final inspection = await _inspect(root);
      if (inspection.root != root) {
        throw StateError('Folder identity changed. Reopen the workspace.');
      }
      final context = store.context(inspection);
      final saved = store.load(root);
      if (!isDisposed) {
        _context = context;
        _inspection = inspection;
        plan = saved;
      }
    } catch (e) {
      if (!isDisposed) error = '$e';
    } finally {
      if (!isDisposed) {
        busy = false;
        update();
      }
    }
  }

  Future<void> saveDraft(String text) => _save(text, false);
  Future<void> decide(bool approved) => _save(plan?.text ?? '', approved);
  Future<void> _save(String text, bool approved) async {
    if (isDisposed || busy || _context == null) return;
    busy = true;
    error = null;
    update();
    try {
      final inspection = await _inspect(root);
      if (isDisposed) return;
      if (inspection.root != root) {
        throw StateError('Folder identity changed. Reopen the workspace.');
      }
      final context = store.context(inspection);
      _context = context;
      _inspection = inspection;
      final saved = await store.save(
        inspection,
        plan,
        text.trim(),
        approved: approved,
      );
      if (!isDisposed) plan = saved;
    } catch (e) {
      if (!isDisposed) {
        _context = null;
        error = '$e';
      }
    } finally {
      if (!isDisposed) {
        busy = false;
        update();
      }
    }
  }
}
