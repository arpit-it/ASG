// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:math';

import '../models/imported_commit_edit_request.dart';
import '../models/imported_commit_edit_record.dart';
import '../models/imported_commit_edit_observation.dart';
import '../models/imported_commit_copy_recheck.dart';
import '../services/imported_commit_copy_recheck_host.dart';
import '../models/project_inspection.dart';
import '../models/imported_commit_proposal_record.dart';
import '../services/folder_picker.dart';
import '../services/imported_commit_edit_store.dart';
import '../services/imported_commit_edit_host.dart';
import 'base_controller.dart';

class ImportedCommitEditController extends BaseController {
  ImportedCommitEditController({
    required this.root,
    required this.store,
    required this.host,
    required this.reader,
    this.inspection,
    this.expectedCopyDigest,
    FolderPicker? picker,
    DateTime Function()? clock,
    String Function()? attemptId,
  }) : _picker = picker ?? FolderPicker(),
       _clock = clock ?? DateTime.now,
       _attemptId = attemptId ?? _nonce;
  final String root;
  final ProjectInspection? inspection;
  final String? expectedCopyDigest;
  final FolderPicker _picker;
  ImportedCommitProposalRecord? get currentProposal => _selected?.saved;
  bool get canPick => canReview && _picker.supported;
  final ImportedCommitEditStore store;
  final ImportedCommitEditHost host;
  final ImportedCommitCopyRecheckHost reader;
  ImportedCommitCopyRecheckRequest? _reviewed;
  ImportedCommitCopyRecheckObservation? _observed;
  bool _reading = false;
  bool get reviewing => _reading;
  final DateTime Function() _clock;
  final String Function() _attemptId;
  ImportedCommitEditRecord? _history;
  ImportedCommitEditSelection? _selected;
  ImportedCommitEditRequest? _draft;
  ImportedCommitEditObservation? _reported;
  Object? _lease;
  int _generation = 0;
  bool _busy = false,
      _ready = false,
      _stopped = false,
      _stale = false,
      _copying = false;
  String? _error;
  ImportedCommitEditRecord? get history => _history;
  ImportedCommitEditRequest? get draft => _draft;
  ImportedCommitEditObservation? get reported => _reported;
  String? get error => _error;
  bool get busy => _busy;
  bool get historyOnly => inspection == null;
  bool get cleanupUncertain =>
      !host.cleanupConfirmed || !reader.cleanupConfirmed;
  bool get workerBlocked => store.readBusy && _lease == null;
  bool get canStop =>
      !isDisposed && _busy && (_copying || _reading) && _lease != null;
  bool get canReview =>
      !isDisposed &&
      !_busy &&
      _ready &&
      host.supported &&
      reader.supported &&
      !cleanupUncertain &&
      !store.readBusy &&
      (_history?.canBegin ?? false);
  bool get stale {
    if (_stale) return true;
    if (_draft == null) return false;
    try {
      store.requireInputs(_selected!.inputs);
      return false;
    } catch (_) {
      return true;
    }
  }

  bool get canPrepare => canReview && _draft != null && !stale;
  bool get canAcknowledge =>
      !isDisposed &&
      !_busy &&
      !cleanupUncertain &&
      !store.readBusy &&
      (_history?.needsRecovery ?? false);
  static String _nonce() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _alive(int generation) {
    if (isDisposed || generation != _generation) {
      throw StateError('Copy view closed.');
    }
    if (_lease != null) store.requireLease(_lease!);
  }

  void _success(int generation) {
    _alive(generation);
    if (_stopped) throw StateError('Copy stopped.');
  }

  void invalidateDraft() {
    if (isDisposed || _busy) return;
    _stale = _draft != null;
    update();
  }

  Future<void> load() async {
    if (isDisposed || _busy) return;
    final generation = ++_generation;
    _busy = true;
    _ready = false;
    _stopped = false;
    _error = null;
    _stale = _draft != null;
    update();
    try {
      _success(generation);
      final history = store.history(root);
      await store.verify(history.inputs, () => _success(generation));
      _success(generation);
      _history = history.record;
      if (historyOnly) return;
      final selected = store.read(inspection!);
      if (selected.saved.root != root ||
          inspection!.root != root ||
          (expectedCopyDigest != null &&
              selected.copyHistory.digest != expectedCopyDigest)) {
        throw StateError('Selected proposal history changed.');
      }
      await store.verify(selected.inputs, () => _success(generation));
      _success(generation);
      _selected = selected;
      _history = selected.history;
      _ready = true;
    } catch (_) {
      if (!isDisposed) _error = 'Saved proposed-copy inputs or history could not be loaded. Existing history is retained. Review the committed plan and runtime, then reload or reopen the app.';
    } finally {
      _busy = false;
      update();
    }
  }

  Future<String?> pickDestination() async {
    if (!canPick) return null;
    final generation = ++_generation;
    _busy = true;
    _stopped = false;
    _error = null;
    update();
    String? picked;
    try {
      _success(generation);
      picked = await _picker.pick();
      _success(generation);
      if (picked != null) _stale = _draft != null;
    } catch (_) {
      if (!isDisposed) {
        _error = 'Destination selection failed. Your typed path is retained.';
      }
    } finally {
      _busy = false;
      update();
    }
    return !isDisposed && generation == _generation && !_stopped
        ? picked
        : null;
  }

  Future<void> review(String destination) async {
    if (!canReview) return;
    try {
      _lease = store.acquire();
    } catch (_) {
      _error = 'Another source worker owns cleanup.';
      update();
      return;
    }
    final generation = ++_generation;
    _busy = true;
    _reading = true;
    _stopped = false;
    _error = null;
    _stale = _draft != null;
    update();
    try {
      _success(generation);
      final selected = store.read(inspection!);
      if (selected.saved.root != root ||
          inspection!.root != root ||
          (expectedCopyDigest != null &&
              selected.copyHistory.digest != expectedCopyDigest)) {
        throw StateError('Selected copy history changed.');
      }
      await store.verify(selected.inputs, () => _success(generation));
      _success(generation);
      final reviewed = ImportedCommitCopyRecheckRequest.create(
        history: selected.copyHistory,
        python: selected.python,
        recheckId: _nonce(),
      );
      final observed = await reader.recheck(reviewed);
      _success(generation);
      if (!reader.cleanupConfirmed ||
          observed.status != ImportedCommitCopyRecheckStatus.matching ||
          observed.requestDigest != reviewed.digest) {
        throw StateError('Original copy could not be confirmed.');
      }
      await store.verify(selected.inputs, () => _success(generation));
      _success(generation);
      final request = ImportedCommitEditRequest.create(
        copyHistory: selected.copyHistory,
        proposal: selected.saved,
        reviewed: reviewed,
        observation: observed,
        python: selected.python,
        destination: destination,
        attemptId: _attemptId(),
      );
      store.requireInputs(selected.inputs);
      _success(generation);
      _selected = selected;
      _history = selected.history;
      _reviewed = reviewed;
      _observed = observed;
      _draft = request;
      _stale = false;
    } catch (_) {
      if (!isDisposed) _error = 'Proposed-copy review failed or stopped. Check current approval, the original copy, trusted Python, destination and supported BOM/legal-header preservation; reload after changed inputs.';
    } finally {
      await _settleWorkers();
      _reading = false;
      _busy = false;
      update();
    }
  }

  Future<void> _settleWorkers() async {
    if (cleanupUncertain) {
      try {
        await Future.wait([host.cancel(), reader.cancel()]);
      } catch (_) {
        /* Retain uncertain shared ownership. */
      }
    }
    if (!cleanupUncertain && _lease != null) {
      store.release(_lease!);
      _lease = null;
    }
  }

  Future<void> prepare(ImportedCommitEditRequest expected) async {
    if (isDisposed || _busy) return;
    if (!canPrepare || !identical(expected, _draft)) {
      _error =
          'Proposed-copy review changed. Review the exact destination again.';
      update();
      return;
    }
    try {
      _lease = store.acquire();
    } catch (_) {
      _error = 'Another source worker owns cleanup. Wait for confirmed cleanup or reconcile it before retrying.';
      update();
      return;
    }
    final generation = ++_generation;
    _copying = true;
    _busy = true;
    _stopped = false;
    _error = null;
    _reported = null;
    update();
    ImportedCommitEditSelection? pending;
    try {
      _success(generation);
      pending = await store.begin(
        _selected!,
        expected,
        _reviewed!,
        _observed!,
        _clock(),
        () => _success(generation),
      );
      _alive(generation);
      _history = pending.history;
      await store.verify(pending.inputs, () => _success(generation));
      _success(generation);
      final result = await host.prepare(expected);
      _alive(generation);
      if (result.requestDigest != expected.digest) {
        throw StateError('Copy receipt changed.');
      }
      _reported = result;
      _success(generation);
      if (!host.cleanupConfirmed) throw StateError('Cleanup uncertain.');
      await store.verify(pending.inputs, () => _success(generation));
      final confirmed = await store.complete(
        pending,
        expected,
        result,
        _clock(),
        () => _success(generation),
      );
      _success(generation);
      _history = confirmed;
      _selected = null;
      _ready = false;
      _stale = true;
      if (result.status == ImportedCommitEditStatus.refused) _error = 'No ready copy was confirmed. Inspect the reported run or destination and confirm the worker stopped before acknowledging recovery.';
    } catch (_) {
      if (!isDisposed) {
        final late = host.lastObservation;
        if (late?.requestDigest == expected.digest) _reported ??= late;
        _error = host.cleanupConfirmed
            ? 'Copy or its durable confirmation is uncertain. Inspect the reported run or destination; reload history before any new attempt.'
            : 'Copy worker cleanup is unconfirmed. New copies remain blocked. Inspect the destination and reconcile the worker before reopening.';
        _ready = false;
        _stale = true;
        if (pending != null) {
          try {
            final recovered = await store.recover(
              pending,
              expected,
              _reported,
              _clock(),
              () => _alive(generation),
            );
            _alive(generation);
            _history = recovered;
          } catch (_) {
            /* Keep the durable pending intent and last loaded history. */
          }
        }
      }
    } finally {
      await _settleWorkers();
      _copying = false;
      _busy = false;
      update();
    }
  }

  Future<void> stop() async {
    if (isDisposed || !_busy || (!_copying && !_reading)) return;
    _stopped = true;
    update();
    try {
      await Future.wait([host.cancel(), reader.cancel()]);
    } catch (_) {
      if (!isDisposed) {
        _error =
            'Copy worker cleanup is unconfirmed. New work remains blocked.';
        update();
      }
    }
  }

  Future<void> acknowledge(
    ImportedCommitEditRecord expected, {
    required bool inspectedAndStopped,
  }) async {
    if (!canAcknowledge ||
        !inspectedAndStopped ||
        !identical(expected, _history)) {
      return;
    }
    final generation = ++_generation;
    try {
      _lease = store.acquire();
    } catch (_) {
      return;
    }
    _busy = true;
    _error = null;
    update();
    try {
      _alive(generation);
      final selected = store.history(root);
      if (selected.record.recordJson != expected.recordJson) {
        throw StateError('History changed.');
      }
      final acknowledged = await store.acknowledge(
        selected,
        _clock(),
        () => _alive(generation),
      );
      _alive(generation);
      _history = acknowledged;
      _selected = null;
      _ready = false;
      _stale = true;
    } catch (_) {
      if (!isDisposed) _error = 'Recovery acknowledgement could not be confirmed. Reload history; nothing is replayed.';
    } finally {
      if (_lease != null) {
        store.release(_lease!);
        _lease = null;
      }
      _busy = false;
      update();
    }
  }

  @override
  void dispose() {
    if (isDisposed) return;
    _generation++;
    _stopped = true;
    unawaited(
      Future.wait([host.dispose(), reader.dispose()]).then<void>(
        (_) {
          if (!cleanupUncertain && _lease != null) {
            store.release(_lease!);
            _lease = null;
          }
        },
        onError: (Object _, StackTrace _) {
          /* Keep uncertain ownership and pending intent. */
        },
      ),
    );
    super.dispose();
  }
}
