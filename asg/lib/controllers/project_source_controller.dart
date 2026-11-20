// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as path;

import '../models/project_source_observation.dart';
import '../services/project_source_host.dart';
import '../services/project_source_host_factory.dart';
import '../services/runtime_setup_store.dart';
import 'base_controller.dart';

typedef ConfirmSourceRead = Future<bool> Function(
  ProjectSourceReadRequest request,
);

/// Manual read/review only. Never sends source file text to a model or storage.
class ProjectSourceController extends BaseController {
  ProjectSourceController({
    required this.root,
    required this._setupStore,
    ProjectSourceHost? host,
  }) : _host = host ?? createProjectSourceHost();
  final String root;
  final RuntimeSetupStore _setupStore;
  final ProjectSourceHost _host;
  bool _busy = false,
      _confirming = false,
      _stale = false,
      _stopped = false,
      _cleanupUncertain = false;
  String? _error;
  ProjectSourceObservation? _findings;
  bool get supported => _host.supported;
  bool get busy => _busy;
  bool get confirming => _confirming;
  bool get stale => _stale;
  bool get cleanupUncertain => _cleanupUncertain;
  bool get canStop => _busy && !_stopped;
  String? get error => _error;
  ProjectSourceObservation? get findings => _findings;

  void invalidateSelection() {
    if (isDisposed || _busy) return;
    _stale = _findings != null;
    update();
  }

  bool _absolute(String value) =>
      path.isAbsolute(value) &&
      path.normalize(value) == value &&
      utf8.encode(value).length <= 4096 &&
      !value.contains(RegExp(r'[\x00-\x1f\x7f]'));

  Future<void> read(
    List<String> selectedPaths, {
    ConfirmSourceRead? confirm,
  }) async {
    if (isDisposed || _busy || _cleanupUncertain) return;
    if (!supported) {
      _error = 'Source file reads are unavailable on this host.';
      update();
      return;
    }
    _busy = true;
    _stopped = false;
    _error = null;
    _stale = _findings != null;
    update();
    try {
      if (isDisposed || _stopped) return;
      final python = _setupStore.load().python;
      if (!_absolute(root) ||
          root == path.separator ||
          !_absolute(python) ||
          path.equals(root.toLowerCase(), python.toLowerCase()) ||
          path.isWithin(root.toLowerCase(), python.toLowerCase())) {
        throw const FormatException();
      }
      final request = ProjectSourceReadRequest(
        root: root,
        python: python,
        selectedPaths: selectedPaths,
      );
      if (confirm == null) {
        _error = 'Confirm the selected source file read before continuing.';
        return;
      }
      _confirming = true;
      update();
      if (isDisposed || _stopped) return;
      final approved = await confirm(request);
      _confirming = false;
      update();
      if (isDisposed || _stopped) return;
      if (!approved) {
        _error = 'Source file read cancelled.';
        return;
      }
      if (_setupStore.load().python != request.python) {
        throw const FormatException();
      }
      final result = await _host.inspect(request);
      if (isDisposed || _stopped) return;
      if (result.status != ProjectSourceStatus.observed ||
          result.selectedPaths.join('|') != request.selectedPaths.join('|')) {
        throw const FormatException();
      }
      _findings = result;
      _stale = false;
    } catch (_) {
      if (!isDisposed && !_stopped) _error = 'Source files could not be read. Check selected files and the configured absolute Python path.';
    } finally {
      try {
        await _host.cancel();
      } catch (_) {
        _cleanupUncertain = true;
        _stale = _findings != null;
        _error = 'Source file helper cleanup could not be confirmed. Reopen after reconciliation.';
      }
      _confirming = false;
      _busy = false;
      update();
    }
  }

  Future<void> cancel() async {
    if (isDisposed || !canStop) return;
    _stopped = true;
    _stale = _findings != null;
    _error = 'Source file read stopped. Close any open confirmation to finish.';
    update();
    try {
      await _host.cancel();
    } catch (_) {
      _cleanupUncertain = true;
      _error = 'Source file helper cleanup could not be confirmed.';
      update();
    }
  }

  @override
  void dispose() {
    if (isDisposed) return;
    super.dispose();
    unawaited(_host.dispose().catchError((Object _) {}));
  }
}
