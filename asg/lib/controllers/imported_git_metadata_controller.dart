// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/git_head_observation.dart';
import '../services/git_metadata_host.dart';
import '../services/runtime_setup_store.dart';
import 'base_controller.dart';

class ImportedGitMetadataController extends BaseController {
  ImportedGitMetadataController({
    required this.root,
    required this.host,
    required this.setupStore,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final String root;
  final GitMetadataHost host;
  final RuntimeSetupStore setupStore;
  final DateTime Function() _now;
  GitMetadataReadRequest? _confirmation;
  GitHeadObservation? _observation;
  DateTime? _readAt;
  String? _error;
  bool _busy = false, _stopRequested = false, _stale = false;
  bool _cleanupUncertain = false;
  Future<void>? _stopping;

  bool get supported => host.supported;
  bool get busy => _busy;
  bool get confirming => _confirmation != null;
  bool get stale => _stale;
  bool get cleanupUncertain => _cleanupUncertain;
  bool get stopping => _stopping != null;
  GitHeadObservation? get observation => _observation;
  DateTime? get readAt => _readAt;
  String? get error => _error;

  /// Reads only application setup; the returned snapshot needs explicit consent.
  GitMetadataReadRequest? prepare() {
    if (isDisposed || busy || confirming || _cleanupUncertain) return null;
    if (!supported) {
      _error = 'Local metadata inspection is unavailable on this platform.';
      update();
      return null;
    }
    try {
      final python = setupStore.load().python.trim();
      if (!_absolute(root) || !_absolute(python)) {
        throw const FormatException();
      }
      _error = null;
      _confirmation = GitMetadataReadRequest(root: root, python: python);
      update();
      return _confirmation;
    } catch (_) {
      _error = 'Choose an existing absolute Python interpreter in Runtime setup before reading metadata. Saved settings have not been changed.';
      update();
      return null;
    }
  }

  static bool _absolute(String value) =>
      value.startsWith('/') &&
      value.length <= 4096 &&
      !value.codeUnits.any((c) => c < 32 || c == 127);

  Future<void> inspect(
    GitMetadataReadRequest request, {
    required bool confirmed,
  }) async {
    if (isDisposed || busy || !identical(request, _confirmation)) return;
    _confirmation = null;
    if (!confirmed) {
      update();
      return;
    }
    _busy = true;
    _stopRequested = false;
    _stopping = null;
    _error = null;
    _stale = _observation != null;
    update();
    try {
      // Listeners may synchronously stop or dispose during the busy notification.
      if (isDisposed || _stopRequested) return;
      final result = await host.inspect(request);
      if (isDisposed || _stopRequested) return;
      _observation = result;
      _readAt = _now();
      _stale = false;
    } catch (_) {
      if (!isDisposed && !_stopRequested) {
        _error = 'Metadata could not be read. Check the configured environment and folder, then retry. Any previous reading is retained.';
        _stale = _observation != null;
        _settleCleanup();
        update();
      }
    } finally {
      final stopping = _stopping;
      if (stopping != null) await stopping;
      _busy = false;
      _stopping = null;
      update();
    }
  }

  Future<void> cancel() async {
    if (isDisposed || !busy || _stopRequested) return;
    _stopRequested = true;
    _stale = _observation != null;
    _error = 'Inspection cancelled. Any previous reading is retained.';
    _settleCleanup();
    update();
    await _stopping;
  }

  void _settleCleanup() {
    _stopping ??= Future<void>.sync(host.cancel).catchError((Object _) {
      _cleanupUncertain = true;
      if (!isDisposed) {
        _error = 'Helper cleanup could not be confirmed. Reconcile the local helper before another inspection.';
        update();
      }
    });
  }

  @override
  void dispose() {
    if (isDisposed) return;
    _confirmation = null;
    _stopRequested = true;
    super.dispose();
    unawaited(Future<void>.sync(host.dispose).catchError((Object _) {}));
  }
}
