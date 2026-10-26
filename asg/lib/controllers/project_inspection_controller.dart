import '../models/project_inspection.dart';
import '../services/folder_picker.dart';
import '../services/project_inspector.dart';
import 'base_controller.dart';

class ProjectInspectionController extends BaseController {
  ProjectInspectionController({
    FolderPicker? picker,
    Future<ProjectInspection> Function(String)? inspect,
  }) : _picker = picker ?? FolderPicker(),
       _inspect = inspect ?? ProjectInspector().inspect;

  final FolderPicker _picker;
  final Future<ProjectInspection> Function(String) _inspect;
  bool _busy = false;
  String? _error;
  ProjectInspection? _findings;
  bool get supported => _picker.supported;
  bool get busy => _busy;
  String? get error => _error;
  ProjectInspection? get findings => _findings;

  Future<void> chooseFolder() async {
    if (isDisposed || _busy) return;
    _error = null;
    if (!supported) {
      _error = 'Folder inspection is unavailable on this platform.';
      update();
      return;
    }
    _busy = true;
    update();
    try {
      final path = await _picker.pick();
      if (isDisposed || path == null) return;
      // Clear previous observations before inspecting a different selection.
      _findings = null;
      update();
      final result = await _inspect(path);
      if (!isDisposed) _findings = result;
    } catch (e) {
      if (!isDisposed) _error = 'Could not inspect this folder: $e';
    } finally {
      if (!isDisposed) {
        _busy = false;
        update();
      }
    }
  }
}
