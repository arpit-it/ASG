// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/candidate_comparison.dart';
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

class CandidateReview {
  const CandidateReview(
    this.snapshot,
    this.python,
    this.digest, {
    this.source,
    this.comparison,
  });

  final String snapshot;
  final String python;
  final String digest;
  final String? source;
  final CandidateComparison? comparison;
}

typedef CandidateFingerprint = Future<String> Function({
  required String snapshot,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
});

typedef CandidateCompare = Future<CandidateComparison> Function({
  required String snapshot,
  required String source,
  required String commit,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
});

class SelfSnapshotController extends BaseController {
  SelfSnapshotController({
    SnapshotPreparation? prepare,
    SnapshotCheck? check,
    CandidateFingerprint? fingerprint,
    CandidateCompare? compare,
    Future<List<String>> Function(String)? inspect,
  }) : _prepare = prepare ?? prepareSelfSnapshot,
       _inspect = inspect ?? inspectIncompleteSnapshots,
       _check = check ?? checkSelfSnapshot,
       _fingerprint = fingerprint ?? fingerprintSelfSnapshot,
       _compare = compare ?? compareSelfSnapshot;

  final SnapshotPreparation _prepare;
  final SnapshotCheck _check;
  final CandidateFingerprint _fingerprint;
  final CandidateCompare _compare;
  int _reviewEpoch = 0;
  CandidateReview? _pendingReview;
  final Future<List<String>> Function(String) _inspect;
  bool _inspecting = false;
  bool get inspecting => _inspecting;
  Completer<void>? _stop;
  bool get busy => _stop != null || _inspecting;
  bool get stopping => _stop?.isCompleted ?? false;
  String? _status;
  String? get status => _status;
  String? _checkOutput;

  /// Temporary diagnostics from the last failed, approved check.
  String? get checkOutput => _checkOutput;

  Future<void> prepare({
    required String source,
    required String destination,
    required String commit,
    required String python,
  }) async {
    if (busy || isDisposed) return;
    discardCandidateReview();
    _checkOutput = null;
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
    discardCandidateReview();
    _checkOutput = null;
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
        if (stop.isCompleted || isDisposed) return;
        final outcome = switch (result) {
          GenerationCommandResult(cancelled: true) => 'stopped',
          GenerationCommandResult(timedOut: true) => 'timed out',
          GenerationCommandResult(outputLimitExceeded: true) =>
            'exceeded the output limit',
          GenerationCommandResult(exitCode: 0) => 'passed',
          _ => 'failed (exit ${result.exitCode})',
        };
        results.add('$label $outcome.');
        if (outcome != 'passed') {
          if (!result.cancelled) {
            const limit = 16384;
            final output = result.output;
            final displayed = output.isEmpty
                ? 'No diagnostic output was captured.'
                : output.length <= limit
                ? output
                : '${output.substring(0, limit)}\n[Output truncated to $limit characters.]';
            _checkOutput = '$label tool output:\n$displayed';
          }
          break;
        }
        final artifact = result.artifactPath;
        if (operation == SelfSnapshotOperation.build && artifact != null) {
          results.add('Web artifacts at $snapshot/asg/$artifact');
        }
      }
    } catch (_) {
      if (!stop.isCompleted) {
        results.add(
          buildWeb
              ? 'Build unavailable. Verify the snapshot and trusted tool paths.'
              : 'Check unavailable. Verify the snapshot and trusted tool paths.',
        );
      }
    } finally {
      if (stop.isCompleted) {
        _checkOutput = null;
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

  Future<CandidateReview?> reviewCandidate({
    required String snapshot,
    required String python,
    String? source,
    String? commit,
  }) async {
    if (busy || isDisposed) return null;
    discardCandidateReview();
    final epoch = _reviewEpoch;
    CandidateComparison? comparison;
    String? digest;
    if (source != null || commit != null) {
      if (source == null ||
          source.isEmpty ||
          commit == null ||
          !RegExp(r'^[a-f0-9]{40}$').hasMatch(commit)) {
        _status = 'Choose a trusted checkout and enter the full reviewed commit for comparison.';
        update();
        return null;
      }
      comparison = await _readReview(
        (stop, stopped) => _compare(
          snapshot: snapshot,
          source: source,
          commit: commit,
          python: python,
          stop: stop,
          stopped: stopped,
        ),
      );
      if (isDisposed || epoch != _reviewEpoch) return null;
      if (comparison != null && comparison.commit != commit) {
        _status = 'Comparison baseline differs from the selected commit.';
        update();
        return null;
      }
      digest = comparison?.digest;
    } else {
      digest = await _scanCandidate(snapshot, python);
    }
    if (digest == null || isDisposed || epoch != _reviewEpoch) return null;
    final review = CandidateReview(
      snapshot,
      python,
      digest,
      source: source,
      comparison: comparison,
    );
    _pendingReview = review;
    return review;
  }

  Future<void> approveCandidate(CandidateReview review) async {
    if (busy || isDisposed || !identical(_pendingReview, review)) return;
    _pendingReview = null;
    final epoch = _reviewEpoch;
    final digest = await _scanCandidate(review.snapshot, review.python);
    if (digest == null || isDisposed || epoch != _reviewEpoch) return;
    _status = digest == review.digest
        ? 'Candidate approved for review only. SHA-256: $digest'
        : 'Candidate changed. Review it again before approving.';
    update();
  }

  void discardCandidateReview() {
    _pendingReview = null;
    _reviewEpoch++;
  }

  Future<String?> _scanCandidate(String snapshot, String python) => _readReview(
    (stop, stopped) => _fingerprint(
      snapshot: snapshot,
      python: python,
      stop: stop,
      stopped: stopped,
    ),
  );

  Future<T?> _readReview<T>(
    Future<T> Function(Future<void>, bool Function()) read,
  ) async {
    _checkOutput = null;
    final stop = Completer<void>();
    _stop = stop;
    _status = 'Reading candidate review…';
    update();
    try {
      if (stop.isCompleted) return null;
      final result = await read(stop.future, () => stop.isCompleted);
      if (stop.isCompleted || isDisposed) return null;
      _status = null;
      return result;
    } catch (_) {
      _status = 'Candidate review unavailable. Verify the selected repository, commit, Python and candidate limits.';
      return null;
    } finally {
      if (stop.isCompleted) {
        _status = 'Candidate review stopped.';
      } else {
        stop.complete();
      }
      _stop = null;
      update();
    }
  }

  void clearStatus() {
    discardCandidateReview();
    if (busy || isDisposed) return;
    if (_status == null && _checkOutput == null) return;
    _status = null;
    _checkOutput = null;
    update();
  }

  Future<void> inspect(String destination) async {
    if (busy || isDisposed || destination.isEmpty) return;
    discardCandidateReview();
    _inspecting = true;
    _status = null;
    _checkOutput = null;
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
    discardCandidateReview();
    _checkOutput = null;
    final current = _stop;
    if (current != null && !current.isCompleted) current.complete();
    super.dispose();
  }
}
