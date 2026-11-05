// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/generation_command_result.dart';
import '../models/self_snapshot_operation.dart';
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

typedef SnapshotCheck = Future<GenerationCommandResult> Function({
  required String snapshot,
  required String sdk,
  required String python,
  required SelfSnapshotOperation operation,
  required Future<void> stop,
  required bool Function() stopped,
});

class SelfSnapshotController extends BaseController {
  SelfSnapshotController({
    SnapshotPreparation? prepare,
    SnapshotCheck? check,
    Future<List<String>> Function(String)? inspect,
  }) : _prepare = prepare ?? prepareSelfSnapshot,
       _inspect = inspect ?? inspectIncompleteSnapshots,
       _check = check ?? checkSelfSnapshot;

  final SnapshotPreparation _prepare;
  final SnapshotCheck _check;
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

  Future<void> check({
    required bool approved,
    bool buildWeb = false,
    required String snapshot,
    required String sdk,
    required String python,
  }) async {
    if (!approved || busy || isDisposed) return;
    final stop = Completer<void>();
    _stop = stop;
    final results = <String>[];
    try {
      for (final operation in [
        SelfSnapshotOperation.resolve,
        if (buildWeb)
          SelfSnapshotOperation.build
        else
          SelfSnapshotOperation.analyze,
      ]) {
        final label = operation.label;
        _status = [...results, '$label running…'].join('\n');
        update();
        if (stop.isCompleted) return;
        final result = await _check(
          snapshot: snapshot,
          sdk: sdk,
          python: python,
          operation: operation,
          stop: stop.future,
          stopped: () => stop.isCompleted,
        );
        if (stop.isCompleted) return;
        final outcome = switch (result) {
          GenerationCommandResult(cancelled: true) => 'stopped',
          GenerationCommandResult(timedOut: true) => 'timed out',
          GenerationCommandResult(outputLimitExceeded: true) =>
            'exceeded the output limit',
          GenerationCommandResult(exitCode: 0) => 'passed',
          _ => 'failed (exit ${result.exitCode})',
        };
        results.add('$label $outcome.');
        if (outcome != 'passed') break;
        if (operation == SelfSnapshotOperation.build) {
          results.add('Web artifacts at $snapshot/asg/build/web');
        }
      }
    } catch (_) {
      if (!stop.isCompleted) {
        results.add(
          buildWeb
              ? 'Build unavailable. Use a prepared snapshot without existing web output and verify the tool paths.'
              : 'Check unavailable. Verify the snapshot and trusted tool paths.',
        );
      }
    } finally {
      if (stop.isCompleted) {
        results.add(
          buildWeb
              ? 'Web build stopped. Any partial output is unverified.'
              : 'Snapshot checks stopped.',
        );
      } else {
        stop.complete();
      }
      _status = results.join('\n');
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
