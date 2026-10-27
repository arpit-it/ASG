// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/project_inspection.dart';
import '../services/folder_picker.dart';
import '../services/inspected_folder_store.dart';
import '../services/project_inspector.dart';
import 'base_controller.dart';

class ProjectInspectionController extends BaseController {
  ProjectInspectionController({
    FolderPicker? picker,
    this.store,
    Future<ProjectInspection> Function(String)? inspect,
  }) : _picker = picker ?? FolderPicker(),
       _inspect = inspect ?? ProjectInspector().inspect {
    try {
      _savedFolders = store?.load() ?? const [];
    } catch (_) {
      _storageError = 'Saved folders could not be loaded. Restore valid local records and storage access, then reopen this screen. Existing records have not been replaced.';
    }
  }

  final InspectedFolderStore? store;
  List<String> _savedFolders = const [];
  List<String> get savedFolders => _savedFolders;
  String? _storageError;
  String? get storageError => _storageError;
  bool get canSave =>
      store != null &&
      _storageError == null &&
      !_busy &&
      _findings != null &&
      !_savedFolders.contains(_findings!.root);

  bool get canOpenWorkspace =>
      !isDisposed &&
      supported &&
      !_busy &&
      _storageError == null &&
      store != null &&
      _findings != null &&
      _savedFolders.contains(_findings!.root);

  /// Never navigate using observations from an earlier selection or reopen.
  Future<ProjectInspection?> openWorkspace() async {
    if (!canOpenWorkspace) return null;
    final root = _findings!.root;
    await reopen(root);
    return !isDisposed && _findings?.root == root ? _findings : null;
  }

  Future<void> saveFolder() async {
    if (isDisposed || !canSave) return;
    final root = _findings!.root;
    _busy = true;
    _error = null;
    update();
    try {
      final roots = await store!.save(root);
      if (!isDisposed) _savedFolders = roots;
    } catch (_) {
      if (!isDisposed) _error = 'Folder reference could not be saved. Check local storage access, then retry saving. Current findings and saved references are retained.';
    } finally {
      if (!isDisposed) {
        _busy = false;
        update();
      }
    }
  }

  Future<void> reopen(String root) async {
    if (isDisposed || _busy || !_savedFolders.contains(root)) return;
    if (!supported) {
      _error = 'Folder inspection is unavailable on this platform.';
      update();
      return;
    }
    _busy = true;
    _error = null;
    _findings = null;
    update();
    try {
      final result = await _inspect(root);
      if (!isDisposed) _findings = result;
    } catch (_) {
      if (!isDisposed) _error = 'Folder could not be reopened. Check that it still exists, is an accessible Flutter project and has a readable pubspec.yaml, then retry. Saved references are retained.';
    } finally {
      if (!isDisposed) {
        _busy = false;
        update();
      }
    }
  }

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
    } catch (_) {
      if (!isDisposed) _error = 'Folder selection or inspection failed. Check local folder access and choose a Flutter project with a readable pubspec.yaml, then retry.';
    } finally {
      if (!isDisposed) {
        _busy = false;
        update();
      }
    }
  }
}
