// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:math';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/imported_workfile_comparison.dart';
import 'imported_index_controller.dart';
import '../services/imported_workfile_host.dart';
import '../services/imported_workfile_store.dart';
import 'base_controller.dart';

class ImportedWorkfileController extends BaseController {
  ImportedWorkfileController({
    required this.root,
    required this.store,
    required this.host,
    required this.index,
    String Function()? comparisonId,
  }) : _comparisonId = comparisonId ?? _nonce {
    index.addListener(_indexChanged);
  }
  final String root;
  final ImportedWorkfileStore store;
  final ImportedWorkfileHost host;
  final String Function() _comparisonId;
  final ImportedIndexController index;
  ImportedWorkfileInputSnapshot? _selected;
  ImportedWorkfileRequest? _confirmation, _resultRequest;
  ImportedWorkfileObservation? _observation, _lastObserved;
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
      !store.readBusy &&
      index.observationCurrent &&
      index.observation?.observed == true;
  bool get canStop => !isDisposed && _busy && _working && !_stopped;
  String? get error => _error;
  ImportedWorkfileObservation? get observation => _observation;
  ImportedWorkfileObservation? get lastObserved => _lastObserved;
  ImportedWorkfileRequest? get resultRequest => _resultRequest;
  bool get observationCurrent {
    if (isDisposed ||
        !_indexMatches ||
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

  bool get _indexMatches {
    final selected = _selected;
    if (selected == null ||
        !index.observationCurrent ||
        index.observation?.observed != true ||
        index.resultRequest?.digest != selected.indexRequest.digest) {
      return false;
    }
    return sha256
            .convert(utf8.encode(index.observation!.recordJson))
            .toString() ==
        selected.request.indexObservationDigest;
  }

  void _indexChanged() {
    if (isDisposed) return;
    if (_selected != null && !_indexMatches) {
      _valid = false;
      _confirmation = null;
      if (_busy && _working) unawaited(cancel());
    }
    update();
  }

  static String _nonce() {
    final r = Random.secure();
    return List.generate(
      16,
      (_) => r.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
  }

  void _alive(int generation) {
    if (isDisposed ||
        generation != _generation ||
        _stopped ||
        (_selected != null && !_indexMatches)) {
      throw StateError('Working-file comparison closed, changed or stopped.');
    }
    if (_lease != null) store.requireLease(_lease!);
  }

  /// Reads only app records; the exact returned snapshot needs explicit consent.
  Future<ImportedWorkfileRequest?> prepare(List<String> paths) async {
    if (!canPrepare) return null;
    final generation = ++_generation;
    _selected = null;
    _busy = true;
    _stopped = false;
    _valid = false;
    _error = null;
    update();
    try {
      _alive(generation);
      final baseline = index.observation, baselineRequest = index.resultRequest;
      if (!index.observationCurrent ||
          baseline?.observed != true ||
          baselineRequest == null) {
        throw StateError('A current explicit index read is required.');
      }
      final selected = store.read(
        root: root,
        indexRequest: baselineRequest,
        indexObservation: baseline!,
        paths: List<String>.of(paths),
        comparisonId: _comparisonId(),
      );
      _selected = selected;
      await store.verify(selected, () => _alive(generation));
      _alive(generation);
      _selected = selected;
      _confirmation = selected.request;
      return _confirmation;
    } catch (_) {
      if (!isDisposed) _error = 'The selected files or current index, folder or interpreter cannot be reviewed. Read the index again and check Runtime setup.';
      return null;
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> inspect(
    ImportedWorkfileRequest expected, {
    required bool confirmed,
  }) async {
    if (isDisposed || _busy || !identical(expected, _confirmation)) return;
    _confirmation = null;
    if (!confirmed) {
      update();
      return;
    }
    if (!supported || cleanupUncertain) {
      _error =
          'Working-file comparison is unavailable or cleanup is unconfirmed.';
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
        throw StateError('Working-file comparison unconfirmed.');
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
            ? 'Comparison stopped, inputs changed or the result could not be confirmed. Previous evidence is historical.'
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
    index.removeListener(_indexChanged);
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
