// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../services/self_snapshot.dart';
import 'base_controller.dart';

typedef SnapshotPreparation = Future<String> Function({
  required String source,
  required String destination,
  required String commit,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
});

class SelfSnapshotController extends BaseController {
  SelfSnapshotController({
    SnapshotPreparation? prepare,
    Future<List<String>> Function(String)? inspect,
  }) : _prepare = prepare ?? prepareSelfSnapshot,
       _inspect = inspect ?? inspectIncompleteSnapshots;

  final SnapshotPreparation _prepare;
  final Future<List<String>> Function(String) _inspect;
  bool _inspecting = false;
  bool get inspecting => _inspecting;
  Completer<void>? _stop;
  bool get busy => _stop != null || _inspecting;
  bool get stopping => _stop?.isCompleted ?? false;
  String? _status;
  String? get status => _status;

  Future<void> prepare({
    required String source,
    required String destination,
    required String commit,
    required String python,
  }) async {
    if (busy || isDisposed) return;
    if (source.isEmpty ||
        destination.isEmpty ||
        python.isEmpty ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(commit)) {
      _status =
          'Choose both folders and enter a Python path and full commit ID.';
      update();
      return;
    }
    final stop = Completer<void>();
    _stop = stop;
    _status = null;
    update();
    const recovery =
        'Check the selected destination for snapshot files before retrying.';
    try {
      if (stop.isCompleted) return;
      final ready = await _prepare(
        source: source,
        destination: destination,
        commit: commit,
        python: python,
        stop: stop.future,
        stopped: () => stop.isCompleted,
      );
      _status = stop.isCompleted
          ? 'Preparation stopped. $recovery'
          : 'Snapshot ready at $ready';
    } catch (_) {
      _status = stop.isCompleted
          ? 'Preparation stopped. $recovery'
          : 'Preparation failed. $recovery';
    } finally {
      if (stop.isCompleted) _status = 'Preparation stopped. $recovery';
      _stop = null;
      update();
    }
  }

  void clearStatus() {
    if (busy || _status == null) return;
    _status = null;
    update();
  }

  Future<void> inspect(String destination) async {
    if (busy || isDisposed || destination.isEmpty) return;
    _inspecting = true;
    _status = null;
    update();
    try {
      final found = await _inspect(destination);
      if (isDisposed) return;
      _status = found.isEmpty
          ? 'No incomplete snapshot folders found.'
          : 'Possible incomplete snapshot folders:\n${found.join('\n')}';
    } catch (_) {
      if (!isDisposed) {
        _status = 'Could not inspect the selected destination. Check access and folder size.';
      }
    } finally {
      _inspecting = false;
      update();
    }
  }

  void stop() {
    final current = _stop;
    if (current == null || current.isCompleted) return;
    current.complete();
    update();
  }

  @override
  void dispose() {
    final current = _stop;
    if (current != null && !current.isCompleted) current.complete();
    super.dispose();
  }
}
