// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:math';

import '../models/imported_commit_copy_recheck.dart';
import '../services/imported_commit_copy_recheck_host.dart';
import '../services/imported_commit_copy_recheck_store.dart';
import 'base_controller.dart';

class ImportedCommitCopyRecheckController extends BaseController {
  ImportedCommitCopyRecheckController({
    required this.root,
    required this.store,
    required this.host,
    this.expectedHistoryDigest,
    String Function()? recheckId,
  }) : _recheckId = recheckId ?? _nonce;
  final String root;
  final String? expectedHistoryDigest;
  final ImportedCommitCopyRecheckStore store;
  final ImportedCommitCopyRecheckHost host;
  final String Function() _recheckId;
  ImportedCommitCopyRecheckSelection? _selected;
  ImportedCommitCopyRecheckRequest? _resultRequest;
  ImportedCommitCopyRecheckObservation? _result, _lastObserved;
  Map<String, String?>? _resultInputs;
  Object? _lease;
  int _generation = 0;
  bool _busy = false,
      _checking = false,
      _stopped = false,
      _ready = false,
      _resultValid = false;
  String? _error;
  ImportedCommitCopyRecheckRequest? get request => _selected?.request;
  ImportedCommitCopyRecheckRequest? get resultRequest => _resultRequest;
  ImportedCommitCopyRecheckObservation? get result => _result;
  ImportedCommitCopyRecheckObservation? get lastObserved => _lastObserved;
  String? get error => _error;
  bool get busy => _busy;
  bool get cleanupUncertain => !host.cleanupConfirmed;
  bool get workerBlocked => store.readBusy && _lease == null;
  bool get canStop => !isDisposed && _busy && _checking;
  bool get canRecheck =>
      !isDisposed &&
      !_busy &&
      _ready &&
      host.supported &&
      host.cleanupConfirmed &&
      !store.readBusy &&
      !stale;
  bool get stale {
    try {
      if (_selected == null) return true;
      store.requireInputs(_selected!.inputs);
      return false;
    } catch (_) {
      return true;
    }
  }

  bool get resultCurrent {
    if (!_resultValid ||
        _result == null ||
        _stopped ||
        _resultRequest?.digest != request?.digest ||
        _resultInputs == null) {
      return false;
    }
    try {
      store.requireInputs(_resultInputs!);
      return true;
    } catch (_) {
      return false;
    }
  }

  static String _nonce() {
    final random = Random.secure();
    return List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _alive(int generation) {
    if (isDisposed || generation != _generation) {
      throw StateError('Recheck closed.');
    }
    if (_lease != null) store.requireLease(_lease!);
  }

  void _success(int generation) {
    _alive(generation);
    if (_stopped) throw StateError('Recheck stopped.');
  }

  Future<void> load() async {
    if (isDisposed || _busy) return;
    final generation = ++_generation;
    _busy = true;
    _ready = false;
    _resultValid = false;
    _stopped = false;
    _error = null;
    update();
    try {
      _success(generation);
      final selected = store.read(
        root,
        _recheckId(),
        expectedHistoryDigest: expectedHistoryDigest,
      );
      await store.verify(selected, () => _success(generation));
      _success(generation);
      _selected = selected;
      _ready = true;
    } catch (_) {
      if (!isDisposed) _error = 'Saved copy inputs cannot be reviewed. Resolve pending recovery and check the current trusted Python configuration, then reopen history.';
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> recheck(ImportedCommitCopyRecheckRequest expected) async {
    if (isDisposed || _busy) return;
    if (!canRecheck || !identical(expected, request)) {
      _error = 'Selected copy review changed. Reload before rechecking.';
      update();
      return;
    }
    try {
      _lease = store.acquire();
    } catch (_) {
      _error =
          'Another source worker owns cleanup. Wait for confirmed cleanup.';
      update();
      return;
    }
    final generation = ++_generation;
    _busy = true;
    _checking = true;
    _ready = false;
    _resultValid = false;
    _stopped = false;
    _error = null;
    update();
    try {
      _success(generation);
      final selected = _selected!;
      await store.verify(selected, () => _success(generation));
      _success(generation);
      final value = await host.recheck(expected);
      _success(generation);
      if (value.requestDigest != expected.digest || !host.cleanupConfirmed) {
        throw StateError('Recheck unconfirmed.');
      }
      await store.verify(selected, () => _success(generation));
      _success(generation);
      if (value.status != ImportedCommitCopyRecheckStatus.refused) {
        _lastObserved = value;
      }
      _result = value;
      _resultValid = true;
      _resultRequest = expected;
      _resultInputs = selected.inputs;
      if (value.status == ImportedCommitCopyRecheckStatus.refused) _error = 'No current copy observation was confirmed. Inspect its output or pending recovery before retrying.';
    } catch (_) {
      if (!isDisposed) {
        _error = host.cleanupConfirmed
            ? 'Recheck stopped, changed inputs or could not be confirmed. Any previous result is historical; saved copy history and outputs are unchanged.'
            : 'Recheck cleanup is unconfirmed. Shared ownership is retained; reconcile the worker before reopening.';
      }
    } finally {
      if (!host.cleanupConfirmed) {
        try {
          await host.cancel();
        } catch (_) {
          /* Retain uncertain ownership. */
        }
      }
      if (host.cleanupConfirmed && _lease != null) {
        store.release(_lease!);
        _lease = null;
      }
      _busy = false;
      _checking = false;
      update();
    }
  }

  Future<void> stop() async {
    if (!canStop) return;
    _stopped = true;
    update();
    try {
      await host.cancel();
    } catch (_) {
      if (!isDisposed) {
        _error = 'Recheck cleanup is unconfirmed. New work remains blocked.';
        update();
      }
    }
  }

  @override
  void dispose() {
    if (isDisposed) return;
    _generation++;
    _stopped = true;
    unawaited(
      host.dispose().then<void>(
        (_) {
          if (host.cleanupConfirmed && _lease != null) {
            store.release(_lease!);
            _lease = null;
          }
        },
        onError: (Object _, StackTrace _) {
          /* Retain uncertain shared lease. */
        },
      ),
    );
    super.dispose();
  }
}
