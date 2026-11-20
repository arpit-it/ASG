// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import '../models/imported_source_baseline.dart';
import '../models/imported_source_proposal_record.dart';
import '../models/project_source_observation.dart';
import '../services/imported_source_baseline_store.dart';
import '../services/project_source_host.dart';
import '../services/project_source_host_factory.dart';
import 'base_controller.dart';

typedef ConfirmBaselineRead = Future<bool> Function(
  ProjectSourceReadRequest request,
);

class ImportedSourceBaselineController extends BaseController {
  ImportedSourceBaselineController({
    required this.saved,
    required this.store,
    ProjectSourceHost? host,
  }) : _host = host ?? createProjectSourceHost();
  final ImportedSourceProposalRecord saved;
  final ImportedSourceBaselineStore store;
  final ProjectSourceHost _host;
  int _generation = 0;
  bool _busy = false,
      _confirming = false,
      _stopped = false,
      _cleanupUncertain = false,
      _stale = false;
  Object? _lease;
  String? _error;
  ImportedSourceBaseline? _comparison, _refusal;
  Map<String, String?>? _lastInputs;
  bool get supported => _host.supported;
  bool get busy => _busy;
  bool get confirming => _confirming;
  bool get cleanupUncertain => _cleanupUncertain;
  bool get canRecheck =>
      !isDisposed && !_busy && !_cleanupUncertain && supported;
  bool get canStop => !isDisposed && _busy && !_stopped;
  bool get blockedByOtherRead => !_busy && store.readOwned;
  String? get error => _error;
  ImportedSourceBaseline? get comparison => _comparison;
  ImportedSourceBaseline? get refusal => _refusal;
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
      throw StateError('Baseline read no longer active.');
    }
  }

  Future<void> recheck({ConfirmBaselineRead? confirm}) async {
    if (isDisposed || _busy || _cleanupUncertain) return;
    if (!supported) {
      _error = 'Contained source reads are unavailable on this host.';
      update();
      return;
    }
    final generation = ++_generation;
    _busy = true;
    _stopped = false;
    _error = null;
    _refusal = null;
    _stale = _comparison != null;
    update();
    ImportedSourceBaselineSelection? selection;
    ImportedSourceBaseline? candidate;
    var cleaned = false;
    try {
      _alive(generation);
      _lease = store.acquireRead();
      selection = store.prepare(saved);
      await store.verify(selection, () => _alive(generation));
      _alive(generation);
      if (confirm == null) {
        _error = 'Confirm the selected source-file read before continuing.';
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
        _error = 'Baseline read cancelled.';
        return;
      }
      await store.verify(selection, () => _alive(generation));
      _alive(generation);
      final observation = await _host.inspect(selection.request);
      _alive(generation);
      candidate = ImportedSourceBaseline.compare(
        saved: selection.saved,
        request: selection.request,
        observation: observation,
        observedAt: DateTime.now().toUtc(),
      );
    } catch (_) {
      if (!isDisposed && !_stopped) _error = 'Baseline read could not be completed. Reload saved history and check the folder, files and absolute Python configuration.';
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
                'Selected source read refused: ${candidate.reason}. Previous result is retained.';
          } else {
            _comparison = candidate;
            _lastInputs = selection.inputs;
            _stale = false;
          }
        } catch (_) {
          if (!isDisposed && !_stopped) _error = 'Saved inputs changed before the result could be confirmed. Previous result is retained; reload history before retrying.';
        }
      }
      if (cleaned && !_cleanupUncertain && _lease != null) {
        store.releaseRead(_lease!);
        _lease = null;
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
    _error =
        'Baseline read stopped. Close any open confirmation to finish cleanup.';
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
