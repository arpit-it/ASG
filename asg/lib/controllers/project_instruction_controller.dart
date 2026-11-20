// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:path/path.dart' as path;

import '../models/project_instruction_observation.dart';
import '../models/project_inspection.dart';
import '../models/imported_document_context.dart';
import '../services/inspected_folder_store.dart';
import '../services/requirements_store.dart';
import '../services/project_instruction_host.dart';
import '../services/project_instruction_host_factory.dart';
import '../services/runtime_setup_store.dart';
import 'base_controller.dart';

typedef ConfirmInstructionRead = Future<bool> Function(
  ProjectInstructionReadRequest request,
);

/// Manual read/review only. Never sends document text to a model or storage.
class ProjectInstructionController extends BaseController {
  ProjectInstructionController({
    required this.root,
    required this._setupStore,
    ProjectInstructionHost? host,
  }) : _host = host ?? createProjectInstructionHost();
  final String root;
  final RuntimeSetupStore _setupStore;
  final ProjectInstructionHost _host;
  bool _busy = false,
      _confirming = false,
      _stale = false,
      _stopped = false,
      _cleanupUncertain = false;
  String? _error;
  ProjectInstructionObservation? _findings;
  ProjectInstructionReadRequest? _capturedRequest;
  bool get supported => _host.supported;
  bool get busy => _busy;
  bool get confirming => _confirming;
  bool get stale => _stale;
  bool get cleanupUncertain => _cleanupUncertain;
  bool get canStop => _busy && !_stopped;
  String? get error => _error;
  ProjectInstructionObservation? get findings => _findings;

  bool get canPreparePlan =>
      !isDisposed &&
      !_busy &&
      !_stale &&
      !_cleanupUncertain &&
      _findings != null &&
      _capturedRequest != null;

  /// Captures current app requirements; does not read files or save a plan.
  ImportedDocumentContext? preparePlan(ProjectInspection inspection) {
    if (!canPreparePlan) return null;
    try {
      if (inspection.root != root ||
          !InspectedFolderStore(_setupStore.records).load().contains(root)) {
        throw const FormatException();
      }
      final findings = _findings!;
      final context = ImportedDocumentContext.capture(
        inspection: inspection,
        requirements: RequirementsStore(_setupStore.records)
            .load(InspectedFolderStore.workspaceId(root)),
        request: _capturedRequest!,
        observation: findings,
      );
      _error = null;
      update();
      return canPreparePlan && identical(_findings, findings) ? context : null;
    } catch (_) {
      _error = 'Planning context could not be prepared. Save the folder reference and review current documents and requirements.';
      update();
      return null;
    }
  }

  bool acceptsPreparedPlan(
    ImportedDocumentContext expected,
    ProjectInspection inspection,
  ) {
    final current = preparePlan(inspection);
    if (current == null) return false;
    if (!expected.matches(current)) {
      _error = 'Captured planning inputs changed. Review documents and requirements again.';
      update();
      return false;
    }
    return canPreparePlan;
  }

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
    ConfirmInstructionRead? confirm,
  }) async {
    if (isDisposed || _busy || _cleanupUncertain) return;
    if (!supported) {
      _error = 'Document reads are unavailable on this host.';
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
      final request = ProjectInstructionReadRequest(
        root: root,
        python: python,
        selectedPaths: selectedPaths,
      );
      if (confirm == null) {
        _error = 'Confirm the selected document read before continuing.';
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
        _error = 'Document read cancelled.';
        return;
      }
      final result = await _host.inspect(request);
      if (isDisposed || _stopped) return;
      if (result.status != ProjectInstructionStatus.observed ||
          result.selectedPaths.join('|') != request.selectedPaths.join('|')) {
        throw const FormatException();
      }
      _findings = result;
      _capturedRequest = request;
      _stale = false;
    } catch (_) {
      if (!isDisposed && !_stopped) _error = 'Documents could not be read. Check selected files and the configured absolute Python path.';
    } finally {
      try {
        await _host.cancel();
      } catch (_) {
        _cleanupUncertain = true;
        _stale = _findings != null;
        _error = 'Document helper cleanup could not be confirmed. Reopen after reconciliation.';
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
    _error = 'Document read stopped. Close any open confirmation to finish.';
    update();
    try {
      await _host.cancel();
    } catch (_) {
      _cleanupUncertain = true;
      _error = 'Document helper cleanup could not be confirmed.';
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
