// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import '../models/imported_commit_comparison.dart';
import '../models/imported_source_baseline.dart';
import '../models/imported_source_proposal_record.dart';
import '../models/imported_commit_source_observation.dart';
import '../services/imported_commit_comparison_store.dart';
import '../services/imported_commit_source_host.dart';
import '../services/imported_commit_source_host_factory.dart';
import 'base_controller.dart';

typedef ConfirmCommitRead = Future<bool> Function(
  ImportedCommitReadRequest request,
);

class ImportedCommitComparisonController extends BaseController {
  ImportedCommitComparisonController({
    required this.saved,
    required this.store,
    ImportedCommitSourceHost? host,
  }) : _host = host ?? createImportedCommitSourceHost();
  final ImportedSourceProposalRecord saved;
  final ImportedCommitComparisonStore store;
  final ImportedCommitSourceHost _host;
  int _generation = 0;
  String _commit = '';
  String get commit => _commit;
  void setCommit(String value) {
    if (isDisposed || value == _commit) return;
    _commit = value;
    if (!_cleanupUncertain) _error = null;
    _stale = _comparison != null;
    if (_busy) unawaited(cancel());
    update();
  }

  bool _busy = false,
      _confirming = false,
      _stopped = false,
      _cleanupUncertain = false,
      _stale = false;
  Object? _lease;
  String? _error;
  ImportedCommitComparison? _comparison, _refusal;
  Map<String, String?>? _lastInputs;
  bool get supported => _host.supported;
  bool get busy => _busy;
  bool get confirming => _confirming;
  bool get cleanupUncertain => _cleanupUncertain;
  bool get canRecheck =>
      !isDisposed &&
      !_busy &&
      !_cleanupUncertain &&
      supported &&
      ImportedCommitReadRequest.validCommit(_commit);
  bool get canStop => !isDisposed && _busy && !_stopped;
  bool get blockedByOtherRead => !_busy && store.readOwned;
  String? get error => _error;
  ImportedCommitComparison? get comparison => _comparison;
  ImportedCommitComparison? get refusal => _refusal;
  bool get stale {
    if (_stale || _comparison == null) return _stale;
    try {
      store.requireInputs(_lastInputs!);
      return false;
    } catch (_) {
      return true;
    }
  }

  void _alive(int generation) {
    if (isDisposed || _stopped || generation != _generation) {
      throw StateError('Commit read no longer active.');
    }
  }

  Future<void> recheck({ConfirmCommitRead? confirm}) async {
    if (isDisposed || _busy || _cleanupUncertain) return;
    if (!supported) {
      _error = 'Immutable commit reads are unavailable on this host.';
      update();
      return;
    }
    if (!ImportedCommitReadRequest.validCommit(_commit)) {
      _error = 'Enter the full 40-character lowercase commit ID.';
      update();
      return;
    }
    final generation = ++_generation;
    final commit = _commit;
    _busy = true;
    _stopped = false;
    _error = null;
    _refusal = null;
    _stale = _comparison != null;
    update();
    ImportedCommitComparisonSelection? selection;
    ImportedCommitComparison? candidate;
    var cleaned = false;
    try {
      _alive(generation);
      _lease = store.acquireRead();
      selection = store.prepare(saved, commit);
      await store.verify(selection, () => _alive(generation));
      _alive(generation);
      if (confirm == null) {
        _error =
            'Confirm the selected immutable commit read before continuing.';
        return;
      }
      _confirming = true;
      update();
      _alive(generation);
      final approved = await confirm(selection.request);
      _confirming = false;
      update();
      _alive(generation);
      if (!approved) {
        _error = 'Commit read cancelled.';
        return;
      }
      await store.verify(selection, () => _alive(generation));
      _alive(generation);
      final observation = await _host.inspect(selection.request);
      _alive(generation);
      if (observation.reason == 'cleanup_uncertain') {
        _cleanupUncertain = true;
        _error = 'Commit reader cleanup could not be confirmed. Reconcile owned work before another read.';
        throw StateError(_error!);
      }
      candidate = ImportedCommitComparison.compare(
        saved: selection.saved,
        request: selection.request,
        observation: observation,
        observedAt: DateTime.now().toUtc(),
      );
    } catch (_) {
      if (!isDisposed && !_stopped && !_cleanupUncertain) _error = 'Commit read could not be completed. Reload saved history and check the folder, files and absolute Python configuration.';
    } finally {
      if (_lease != null) {
        try {
          await _host.cancel();
          cleaned = true;
        } catch (_) {
          _cleanupUncertain = true;
          _stale = _comparison != null;
          _error = 'Source-reader cleanup could not be confirmed. Reconcile owned work before another read.';
        }
      }
      if (candidate != null &&
          selection != null &&
          cleaned &&
          !_cleanupUncertain &&
          !isDisposed &&
          !_stopped) {
        try {
          await store.verify(selection, () => _alive(generation));
          _alive(generation);
          if (candidate.status == ImportedSourceBaselineStatus.refused) {
            _refusal = candidate;
            _error =
                'Immutable commit read refused: ${candidate.reason}. Previous result is retained.';
          } else {
            _comparison = candidate;
            _lastInputs = selection.inputs;
            _stale = false;
          }
        } catch (_) {
          if (!isDisposed && !_stopped) _error = 'Saved inputs changed before the commit result could be confirmed. Previous result is retained; reload history before retrying.';
        }
      }
      if (cleaned && !_cleanupUncertain && _lease != null) {
        store.releaseRead(_lease!);
        _lease = null;
      }
      if (_stopped && !_cleanupUncertain && !isDisposed) {
        _error = 'Commit read stopped. Saved history is preserved.';
      }
      _confirming = false;
      _busy = false;
      update();
    }
  }

  Future<void> cancel() async {
    if (!canStop) return;
    _stopped = true;
    _stale = _comparison != null;
    _error = _confirming
        ? 'Commit read stopped. Close the open confirmation to finish cleanup.'
        : 'Commit read stopped. Waiting for owned cleanup.';
    update();
    if (_lease != null) {
      try {
        await _host.cancel();
      } catch (_) {
        _cleanupUncertain = true;
        _error = 'Source-reader cleanup could not be confirmed. Reconciliation is required.';
        update();
      }
    }
  }

  @override
  void dispose() {
    if (isDisposed) return;
    _generation++;
    _stopped = true;
    super.dispose();
    unawaited(
      _host.dispose().catchError((Object _) {
        if (_lease != null) _cleanupUncertain = true;
      }),
    );
  }
}
