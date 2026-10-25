import 'dart:async';

import '../models/app_definition.dart';
import '../models/project.dart';
import '../models/source_generation.dart';
import '../services/generation_host.dart';
import '../services/folder_picker.dart';
import '../services/source_generation_store.dart';
import '../services/runtime_setup_store.dart';
import 'base_controller.dart';

class SourceGenerationController extends BaseController {
  SourceGenerationController({
    required this.project,
    required this.definition,
    required this.store,
    required this.host,
  }) {
    try {
      _result = store.load(project.id);
      _initialPython = RuntimeSetupStore(store.records).load().python;
    } catch (e) {
      _error =
          'Generation settings or history could not be read. It has not been overwritten. $e';
      _historyInvalid = true;
    }
  }
  final StudioProject project;
  final AppDefinition definition;
  final SourceGenerationStore store;
  final GenerationHost host;
  GeneratedProject? _result;
  GeneratedProject? get result => _result;
  String _initialPython = 'python3';
  String get initialPython => _result?.python ?? _initialPython;
  String? _error;
  String? get error => _error;
  bool _busy = false, _historyInvalid = false;
  bool get busy => _busy;
  bool get available =>
      host.supported && !_historyInvalid && project.type == 'Flutter';
  Uri? _preview;
  Uri? get preview => _preview;

  Future<String?> chooseDirectory(FolderPicker picker) async {
    if (_busy || !available || !picker.supported || isDisposed) return null;
    _busy = true;
    _error = null;
    update();
    try {
      final selected = await picker.pick();
      return isDisposed ? null : selected;
    } catch (e) {
      if (!isDisposed) _error = 'Directory could not be selected: $e';
      return null;
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> _save(GeneratedProject value) async {
    if (isDisposed) throw StateError('Generation screen closed.');
    await store.save(project.id, value);
    if (isDisposed) return;
    _result = value;
    update();
  }

  Future<void> _failure(GeneratedProject? active, Object error) async {
    if (isDisposed) return;
    _error = 'Generation stopped; existing files were preserved. $error';
    if (active == null) return;
    final latest = _result?.directory == active.directory ? _result! : active;
    try {
      await _save(
        latest.copy(phase: SourceGenerationPhase.failed, error: _error!),
      );
    } catch (_) {
      _error =
          '$_error The failed outcome could not be saved; previous durable history remains intact.';
    }
  }

  Future<bool> generate({
    required String parent,
    required String name,
    required String sdk,
    required String python,
    required bool approved,
  }) async {
    if (!approved || _busy || !available || isDisposed) return false;
    _busy = true;
    _error = null;
    update();
    GeneratedProject? active;
    try {
      await host.stopPreview();
      if (isDisposed) return false;
      _preview = null;
      active = await host.generate(
        project: project,
        definition: definition,
        parent: parent,
        name: name,
        sdk: sdk,
        python: python,
      );
      if (isDisposed) return false;
      await _save(active);
      if (isDisposed) return false;
      final verified = await host.verify(active, _save);
      return !isDisposed && verified.phase == SourceGenerationPhase.ready;
    } catch (e) {
      await _failure(active, e);
      return false;
    } finally {
      _busy = false;
      update();
    }
  }

  Future<bool> verifyAgain({
    required bool approved,
    String? sdk,
    String? python,
  }) async {
    final current = _result?.copy(
      sdk: sdk == null || sdk.trim().isEmpty ? null : sdk.trim(),
      python: python == null || python.trim().isEmpty ? null : python.trim(),
    );
    if (!approved || _busy || !available || current == null || isDisposed) {
      return false;
    }
    _busy = true;
    _error = null;
    update();
    try {
      await host.stopPreview();
      if (isDisposed) return false;
      _preview = null;
      final verified = await host.verify(current, _save);
      return !isDisposed && verified.phase == SourceGenerationPhase.ready;
    } catch (e) {
      await _failure(current, e);
      return false;
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> startPreview() async {
    final current = _result;
    if (_busy || !available || current == null || isDisposed) return;
    _busy = true;
    _error = null;
    update();
    try {
      final uri = await host.startPreview(current);
      if (isDisposed) {
        await host.stopPreview();
        return;
      }
      _preview = uri;
    } catch (e) {
      if (!isDisposed) _error = '$e';
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> openPreview() async {
    final uri = _preview;
    if (uri == null || _busy || isDisposed) return;
    try {
      await host.openPreview(uri);
    } catch (e) {
      _error = '$e';
      update();
    }
  }

  Future<void> stopPreview() async {
    await host.stopPreview();
    _preview = null;
    update();
  }

  @override
  void dispose() {
    unawaited(host.dispose().catchError((Object _) {}));
    super.dispose();
  }
}
