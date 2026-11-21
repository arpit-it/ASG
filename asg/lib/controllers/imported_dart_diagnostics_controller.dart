// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:math';

import '../models/imported_commit_edit_comparison.dart';
import '../models/imported_dart_diagnostics.dart';
import '../services/imported_commit_edit_comparison_store.dart';
import '../services/imported_dart_diagnostics_host.dart';
import '../services/imported_dart_diagnostics_store.dart';
import 'base_controller.dart';

class ImportedDartDiagnosticsController extends BaseController {
  ImportedDartDiagnosticsController({
    required this.comparison,
    required this.observation,
    required this.store,
    required this.host,
    String Function()? runId,
  }) : _runId = runId ?? _nonce;
  final ImportedCommitEditComparisonRequest comparison;
  final ImportedCommitEditComparisonObservation observation;
  final ImportedDartDiagnosticsStore store;
  final ImportedDartDiagnosticsHost host;
  final String Function() _runId;
  ImportedCommitEditComparisonSelection? _selected;
  ImportedDartDiagnosticsRequest? _request, _resultRequest;
  ImportedDartDiagnosticsObservation? _result, _lastObserved;
  Object? _lease;
  int _generation = 0;
  bool _busy = false,
      _working = false,
      _stopped = false,
      _ready = false,
      _resultValid = false;
  String? _error;
  ImportedDartDiagnosticsRequest? get request => _request;
  ImportedDartDiagnosticsRequest? get resultRequest => _resultRequest;
  ImportedDartDiagnosticsObservation? get result => _result;
  ImportedDartDiagnosticsObservation? get lastObserved => _lastObserved;
  String? get error => _error;
  bool get busy => _busy;
  bool get supported => host.supported;
  bool get cleanupUncertain => !host.cleanupConfirmed;
  bool get workerBlocked => store.readBusy && _lease == null;
  bool get canStop => !isDisposed && _busy && _working;
  bool get stale {
    try {
      if (_selected == null) return true;
      store.requireInputs(_selected!.inputs);
      return false;
    } catch (_) {
      return true;
    }
  }

  bool get canReview =>
      !isDisposed &&
      !_busy &&
      _ready &&
      host.supported &&
      host.cleanupConfirmed &&
      !store.readBusy &&
      !stale;
  bool get canDiagnose => canReview && _request != null;
  bool get resultCurrent =>
      !isDisposed &&
      _resultValid &&
      !_stopped &&
      _result != null &&
      _resultRequest != null &&
      !stale;
  static String _nonce() {
    final r = Random.secure();
    return List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _alive(int generation) {
    if (isDisposed || generation != _generation || _stopped) {
      throw StateError('Diagnostics closed or stopped.');
    }
    if (_lease != null) store.requireLease(_lease!);
  }

  Future<void> load() async {
    if (isDisposed || _busy) return;
    final generation = ++_generation;
    _busy = true;
    _ready = false;
    _request = null;
    _resultValid = false;
    _stopped = false;
    _error = null;
    update();
    try {
      final selected = store.select(comparison, observation);
      await store.verify(selected, () => _alive(generation));
      _alive(generation);
      _selected = selected;
      _ready = true;
    } catch (_) {
      if (!isDisposed) _error = 'Copy comparison inputs changed or recovery is pending. Reopen and compare the copies again.';
    } finally {
      _busy = false;
      update();
    }
  }

  void clearReview() {
    if (isDisposed || _busy) return;
    _request = null;
    update();
  }

  Future<void> reviewSdk(String sdkRoot) async {
    if (!canReview) return;
    await _work((generation, selected) async {
      _request = null;
      final sdk = await host.reviewSdk(
        comparison: comparison,
        sdkRoot: sdkRoot,
      );
      _alive(generation);
      if (!host.cleanupConfirmed || sdk.root != sdkRoot) {
        throw StateError('SDK review unconfirmed.');
      }
      await store.verify(selected, () => _alive(generation));
      _alive(generation);
      _request = store.request(
        selected: selected,
        observation: observation,
        sdk: sdk,
        runId: _runId(),
      );
    });
  }

  /// The view passes the exact reviewed request only after explicit user consent.
  Future<void> diagnose(ImportedDartDiagnosticsRequest expected) async {
    if (!canDiagnose || !identical(expected, _request)) {
      if (!isDisposed && !_busy) {
        _error = 'Review the SDK and selected bytes again before consenting.';
        update();
      }
      return;
    }
    await _work((generation, selected) async {
      _request =
          null; // A reviewed intent is single use, including failed runs.
      final value = await host.diagnose(expected);
      _alive(generation);
      if (!host.cleanupConfirmed || value.requestDigest != expected.digest) {
        throw StateError('Diagnostics unconfirmed.');
      }
      await store.verify(selected, () => _alive(generation));
      _alive(generation);
      _result = value;
      _resultRequest = expected;
      _resultValid = true;
      if (value.completed) _lastObserved = value;
      if (!value.completed) _error = 'Isolated diagnostics were unavailable or stopped. Review again before retrying.';
    });
  }

  Future<void> _work(
    Future<void> Function(int, ImportedCommitEditComparisonSelection) operation,
  ) async {
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
    _resultValid = false;
    _error = null;
    update();
    try {
      _alive(generation);
      final selected = _selected!;
      await store.verify(selected, () => _alive(generation));
      _alive(generation);
      await operation(generation, selected);
    } catch (_) {
      _request = null;
      if (!isDisposed) {
        _error = host.cleanupConfirmed
            ? 'Diagnostics stopped, inputs changed or the result could not be confirmed. Previous evidence is historical; saved outputs are unchanged.'
            : 'Worker cleanup is unconfirmed. Shared ownership remains held until reconciled.';
      }
    } finally {
      if (!host.cleanupConfirmed) {
        try {
          await host.cancel();
        } catch (_) {
          /* Retain unknown ownership. */
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

  Future<void> stop() async {
    if (!canStop) return;
    _stopped = true;
    _request = null;
    _resultValid = false;
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
    unawaited(
      host.dispose().then<void>(
        (_) {
          if (host.cleanupConfirmed && _lease != null) {
            store.release(_lease!);
            _lease = null;
          }
        },
        onError: (Object _, StackTrace _) {
          /* Retain uncertain lease. */
        },
      ),
    );
    super.dispose();
  }
}
