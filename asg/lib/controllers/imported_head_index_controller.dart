// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:math';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/imported_head_index_observation.dart';
import 'imported_workfile_controller.dart';
import '../services/imported_head_index_host.dart';
import '../services/imported_head_index_store.dart';
import 'base_controller.dart';

class ImportedHeadIndexController extends BaseController {
  ImportedHeadIndexController({
    required this.root,
    required this.store,
    required this.host,
    required this.workfile,
    String Function()? readId,
  }) : _readId = readId ?? _nonce {
    workfile.addListener(_workfileChanged);
  }
  final String root;
  final ImportedHeadIndexStore store;
  final ImportedHeadIndexHost host;
  final String Function() _readId;
  final ImportedWorkfileController workfile;
  ImportedHeadIndexInputSnapshot? _selected;
  ImportedHeadIndexRequest? _confirmation, _resultRequest;
  ImportedHeadIndexObservation? _observation, _lastObserved;
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
      workfile.observationCurrent &&
      workfile.observation?.observed == true;
  bool get canStop => !isDisposed && _busy && _working && !_stopped;
  String? get error => _error;
  ImportedHeadIndexObservation? get observation => _observation;
  ImportedHeadIndexObservation? get lastObserved => _lastObserved;
  ImportedHeadIndexRequest? get resultRequest => _resultRequest;
  bool get observationCurrent {
    if (isDisposed ||
        !_workfileMatches ||
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

  bool get _workfileMatches {
    final selected = _selected;
    if (selected == null ||
        !workfile.observationCurrent ||
        workfile.observation?.observed != true ||
        workfile.resultRequest?.digest != selected.workfileRequest.digest) {
      return false;
    }
    return sha256
            .convert(utf8.encode(workfile.observation!.recordJson))
            .toString() ==
        selected.request.workfileObservationDigest;
  }

  void _workfileChanged() {
    if (isDisposed) return;
    if (_selected != null && !_workfileMatches) {
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
        (_selected != null && !_workfileMatches)) {
      throw StateError('Declared-object read closed, changed or stopped.');
    }
    if (_lease != null) store.requireLease(_lease!);
  }

  /// Reads only app records; the exact returned snapshot needs explicit consent.
  Future<ImportedHeadIndexRequest?> prepare() async {
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
      final baseline = workfile.observation,
          baselineRequest = workfile.resultRequest;
      if (!workfile.observationCurrent ||
          baseline?.observed != true ||
          baselineRequest == null) {
        throw StateError(
          'A current explicit selected-file comparison is required.',
        );
      }
      final selected = store.read(
        root: root,
        workfileRequest: baselineRequest,
        workfileObservation: baseline!,
        readId: _readId(),
      );
      _selected = selected;
      await store.verify(selected, () => _alive(generation));
      _alive(generation);
      _selected = selected;
      _confirmation = selected.request;
      return _confirmation;
    } catch (_) {
      if (!isDisposed) _error = 'The current selected-file read, index, folder or interpreter cannot be reviewed. Compare selected files again and check Runtime setup.';
      return null;
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> inspect(
    ImportedHeadIndexRequest expected, {
    required bool confirmed,
  }) async {
    if (isDisposed || _busy || !identical(expected, _confirmation)) return;
    _confirmation = null;
    if (!confirmed) {
      update();
      return;
    }
    if (!supported || cleanupUncertain) {
      _error = 'Declared-object read is unavailable or cleanup is unconfirmed.';
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
        throw StateError('Declared-object read unconfirmed.');
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
            ? 'Declared-object read stopped, inputs changed or the result could not be confirmed. Previous evidence is historical.'
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
    workfile.removeListener(_workfileChanged);
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
