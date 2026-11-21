// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:math';

import '../models/imported_index_observation.dart';
import '../services/imported_index_host.dart';
import '../services/imported_index_store.dart';
import 'base_controller.dart';

class ImportedIndexController extends BaseController {
  ImportedIndexController({
    required this.root,
    required this.store,
    required this.host,
    String Function()? readId,
  }) : _readId = readId ?? _nonce;
  final String root;
  final ImportedIndexStore store;
  final ImportedIndexHost host;
  final String Function() _readId;
  ImportedIndexSelection? _selected;
  ImportedIndexReadRequest? _confirmation, _resultRequest;
  ImportedIndexObservation? _observation, _lastObserved;
  Map<String, String?>? _resultInputs;
  Object? _lease;
  int _generation = 0;
  bool _busy = false, _working = false, _stopped = false, _valid = false;
  String? _error;
  bool get supported => host.supported;
  bool get busy => _busy;
  bool get confirming => _confirmation != null;
  bool get stopping => _busy && _working && _stopped;
  bool get cleanupUncertain => !host.cleanupConfirmed;
  bool get workerBlocked => store.readBusy && _lease == null;
  bool get canPrepare =>
      !isDisposed &&
      !_busy &&
      !confirming &&
      supported &&
      !cleanupUncertain &&
      !store.readBusy;
  bool get canStop => !isDisposed && _busy && _working && !_stopped;
  String? get error => _error;
  ImportedIndexObservation? get observation => _observation;
  ImportedIndexObservation? get lastObserved => _lastObserved;
  ImportedIndexReadRequest? get resultRequest => _resultRequest;
  bool get observationCurrent {
    if (isDisposed ||
        !_valid ||
        _stopped ||
        _observation == null ||
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
    final r = Random.secure();
    return List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _alive(int generation) {
    if (isDisposed || generation != _generation || _stopped) {
      throw StateError('Index read closed or stopped.');
    }
    if (_lease != null) store.requireLease(_lease!);
  }

  /// Reads only app records; the exact returned snapshot needs explicit consent.
  Future<ImportedIndexReadRequest?> prepare() async {
    if (!canPrepare) return null;
    final generation = ++_generation;
    _busy = true;
    _stopped = false;
    _valid = false;
    _error = null;
    update();
    try {
      _alive(generation);
      final selected = store.read(root, _readId());
      await store.verify(selected, () => _alive(generation));
      _alive(generation);
      _selected = selected;
      _confirmation = selected.request;
      return _confirmation;
    } catch (_) {
      if (!isDisposed) _error = 'The folder or current interpreter cannot be reviewed. Reopen the folder and check Runtime setup.';
      return null;
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> inspect(
    ImportedIndexReadRequest expected, {
    required bool confirmed,
  }) async {
    if (isDisposed || _busy || !identical(expected, _confirmation)) return;
    _confirmation = null;
    if (!confirmed) {
      update();
      return;
    }
    if (!supported || cleanupUncertain) {
      _error = 'Local index reading is unavailable or cleanup is unconfirmed.';
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
    _working = true;
    _stopped = false;
    _valid = false;
    _error = null;
    update();
    try {
      _alive(generation);
      final selected = _selected!;
      await store.verify(selected, () => _alive(generation));
      _alive(generation);
      final value = await host.inspect(expected);
      _alive(generation);
      if (!host.cleanupConfirmed || value.requestDigest != expected.digest) {
        throw StateError('Index observation unconfirmed.');
      }
      await store.verify(selected, () => _alive(generation));
      _alive(generation);
      _observation = value;
      _resultRequest = expected;
      _resultInputs = selected.inputs;
      _valid = true;
      if (value.observed) _lastObserved = value;
    } catch (_) {
      if (!isDisposed) {
        _error = host.cleanupConfirmed
            ? 'Index reading stopped, inputs changed or the result could not be confirmed. Previous evidence is historical.'
            : 'Worker cleanup is unconfirmed. Shared ownership remains held until reconciled.';
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
      _working = false;
      update();
    }
  }

  Future<void> cancel() async {
    if (!canStop) return;
    _stopped = true;
    _valid = false;
    update();
    try {
      await host.cancel();
    } catch (_) {
      if (!isDisposed) {
        _error = 'Worker cleanup is unconfirmed. New work remains blocked.';
        update();
      }
    }
  }

  @override
  void dispose() {
    if (isDisposed) return;
    _generation++;
    _stopped = true;
    _confirmation = null;
    unawaited(
      host.dispose().then<void>(
        (_) {
          if (host.cleanupConfirmed && _lease != null) {
            store.release(_lease!);
            _lease = null;
          }
        },
        onError: (Object _, StackTrace _) {
          /* Retain uncertain ownership. */
        },
      ),
    );
    super.dispose();
  }
}
