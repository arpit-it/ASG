// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import '../models/project_inspection.dart';
import '../models/project_metadata_observation.dart';
import '../services/folder_picker.dart';
import '../services/inspected_folder_store.dart';
import '../services/project_inspector.dart';
import '../services/project_metadata_host.dart';
import '../services/runtime_setup_store.dart';
import 'base_controller.dart';

typedef ConfirmProjectInspection = Future<bool> Function(
  ProjectMetadataReadRequest request,
);

class ProjectInspectionController extends BaseController {
  ProjectInspectionController({
    FolderPicker? picker,
    this.store,
    Future<ProjectInspection> Function(String)? inspect,
    RuntimeSetupStore? setupStore,
    ProjectMetadataHost? host,
  }) : _picker = picker ?? FolderPicker(),
       _injectedInspect = inspect,
       _inspector = ProjectInspector(host: host),
       _setupStore =
           setupStore ??
           (store == null ? null : RuntimeSetupStore(store.records)) {
    try {
      _savedFolders = store?.load() ?? const [];
    } catch (_) {
      _storageError = 'Saved folders could not be loaded. Restore valid local records and storage access, then reopen this screen. Existing records have not been replaced.';
    }
  }

  final InspectedFolderStore? store;
  final FolderPicker _picker;
  final Future<ProjectInspection> Function(String)? _injectedInspect;
  final ProjectInspector _inspector;
  final RuntimeSetupStore? _setupStore;
  List<String> _savedFolders = const [];
  String? _storageError, _error;
  ProjectInspection? _findings;
  bool _busy = false, _saving = false, _confirming = false;
  bool _stale = false, _stopRequested = false, _cleanupUncertain = false;
  Future<void>? _stopping;

  List<String> get savedFolders => _savedFolders;
  String? get storageError => _storageError;
  String? get error => _error;
  ProjectInspection? get findings => _findings;
  bool get busy => _busy;
  bool get confirming => _confirming;
  bool get saving => _saving;
  bool get stale => _stale;
  bool get cleanupUncertain => _cleanupUncertain;
  bool get stopping => _stopRequested || _stopping != null;
  bool get canStop => _busy && !_saving && !_stopRequested;
  bool get supported =>
      _picker.supported && (_injectedInspect != null || _inspector.supported);
  bool get _canStart => !isDisposed && !_busy && !_cleanupUncertain;
  bool get canSave =>
      _canStart &&
      !_stale &&
      store != null &&
      _storageError == null &&
      _findings != null &&
      !_savedFolders.contains(_findings!.root);
  bool get canOpenWorkspace =>
      _canStart &&
      !_stale &&
      supported &&
      _storageError == null &&
      store != null &&
      _findings != null &&
      _savedFolders.contains(_findings!.root);

  /// The view supplies consent and navigates only with a fresh successful result.
  Future<ProjectInspection?> openWorkspace({
    ConfirmProjectInspection? confirm,
  }) async {
    if (!canOpenWorkspace) return null;
    final result = await reopen(_findings!.root, confirm: confirm);
    return !isDisposed &&
            !_stopRequested &&
            !_stale &&
            identical(_findings, result)
        ? result
        : null;
  }

  void _begin() {
    _busy = true;
    _stopRequested = false;
    _stopping = null;
    _error = null;
    update();
  }

  Future<void> _finish() async {
    final stopping = _stopping;
    if (stopping != null) await stopping;
    _busy = false;
    _saving = false;
    _confirming = false;
    _stopping = null;
    update();
  }

  Future<void> saveFolder() async {
    if (!canSave) return;
    final root = _findings!.root;
    _saving = true;
    _begin();
    try {
      if (isDisposed) return;
      final roots = await store!.save(root);
      if (!isDisposed) _savedFolders = roots;
    } catch (_) {
      if (!isDisposed) _error = 'Folder reference could not be saved. Check local storage access, then retry saving. Current findings and saved references are retained.';
    } finally {
      await _finish();
    }
  }

  Future<ProjectInspection?> reopen(
    String root, {
    ConfirmProjectInspection? confirm,
  }) async {
    if (!_canStart || !_savedFolders.contains(root)) return null;
    if (!supported) {
      _error = 'Contained folder inspection is unavailable on this platform.';
      update();
      return null;
    }
    _begin();
    try {
      if (isDisposed || _stopRequested) return null;
      return await _read(root, confirm);
    } finally {
      await _finish();
    }
  }

  Future<ProjectInspection?> chooseFolder({
    ConfirmProjectInspection? confirm,
  }) async {
    if (!_canStart) return null;
    if (!supported) {
      _error = 'Contained folder inspection is unavailable on this platform.';
      update();
      return null;
    }
    _begin();
    try {
      if (isDisposed || _stopRequested) return null;
      final root = await _picker.pick();
      if (isDisposed || _stopRequested || root == null) return null;
      return await _read(root, confirm);
    } catch (_) {
      if (!isDisposed && !_stopRequested) _error = 'Folder selection failed. Check local folder access, then retry. Saved references are retained.';
      return null;
    } finally {
      await _finish();
    }
  }

  static bool _absolute(String value) =>
      value.startsWith('/') &&
      utf8.encode(value).length <= 4096 &&
      !value.codeUnits.any((c) => c < 32 || c == 127);

  Future<ProjectInspection?> _read(
    String root,
    ConfirmProjectInspection? confirm,
  ) async {
    _stale = _findings != null;
    late final String python;
    try {
      python = _setupStore?.load().python ?? '';
      if (!_absolute(root) || !_absolute(python)) throw const FormatException();
    } catch (_) {
      _error = 'Choose an existing absolute Python interpreter in Runtime setup before inspection. Saved folders and settings have not changed.';
      update();
      return null;
    }
    if (confirm == null) {
      _error = 'Inspection needs explicit confirmation. Previous findings are retained.';
      update();
      return null;
    }
    final request = ProjectMetadataReadRequest(root: root, python: python);
    _confirming = true;
    update();
    try {
      if (isDisposed || _stopRequested) return null;
      final approved = await confirm(request);
      _confirming = false;
      update();
      if (isDisposed || _stopRequested) return null;
      if (!approved) {
        _error = 'Inspection cancelled. Previous findings and saved references are retained.';
        return null;
      }
      // A listener may synchronously Stop or dispose after the notification.
      if (isDisposed || _stopRequested) return null;
      final result = _injectedInspect == null
          ? await _inspector.inspect(request.root, python: request.python)
          : await _injectedInspect(request.root);
      if (isDisposed || _stopRequested) return null;
      if (result.root != request.root) throw const FormatException();
      _findings = result;
      _stale = false;
      return result;
    } catch (_) {
      if (!isDisposed && !_stopRequested) {
        _error = 'Folder metadata could not be read. Check the folder and configured interpreter, then retry. Previous findings and saved references are retained.';
        _settleCleanup();
        update();
      }
      return null;
    } finally {
      _confirming = false;
    }
  }

  void _settleCleanup() {
    _stopping ??= Future<void>.sync(_inspector.cancel).catchError((Object _) {
      _cleanupUncertain = true;
      if (!isDisposed) _error = 'Helper cleanup could not be confirmed. Reconcile the local helper before another inspection.';
      update();
    });
  }

  Future<void> cancel() async {
    if (isDisposed || !canStop) return;
    _stopRequested = true;
    _stale = _findings != null;
    _error = 'Inspection stopped. Close any open folder chooser or confirmation to finish. Previous findings are retained.';
    _settleCleanup();
    update();
    await _stopping;
  }

  @override
  void dispose() {
    if (isDisposed) return;
    _stopRequested = true;
    super.dispose();
    unawaited(Future<void>.sync(_inspector.dispose).catchError((Object _) {}));
  }
}
