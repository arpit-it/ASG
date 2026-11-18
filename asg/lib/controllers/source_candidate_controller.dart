// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/agent_execution_checkpoint.dart';
import '../models/candidate_operation_receipt.dart';
import '../models/candidate_stop_request.dart';
import '../models/candidate_recovery_status.dart';
import '../models/candidate_recovery_acknowledgement.dart';
import '../services/agent_execution_checkpoint_store.dart';
import '../models/approved_source_proposal.dart';
import '../models/build_plan.dart';
import '../models/candidate_failure.dart';
import '../models/candidate_verification_run.dart';
import '../services/candidate_verification_store.dart';
import '../services/requirements_store.dart';
import '../models/project.dart';
import '../models/source_generation.dart';
import '../services/application_store.dart';
import '../services/approved_source_proposer.dart';
import '../services/generation_host.dart';
import '../services/generation_input.dart';
import '../services/record_storage.dart';
import 'base_controller.dart';

typedef CandidatePromotion = Future<Uri> Function(
  GeneratedProject candidate,
  GenerationHost host,
  void Function() authorize,
);

/// Owns confined candidate checks, never writes the working generation record.
class SourceCandidateController extends BaseController {
  SourceCandidateController({
    required this.project,
    required GeneratedProject candidate,
    required this.evidence,
    required this.records,
    required this.host,
    required this.publish,
    this.requireWorking,
  }) : _result = candidate {
    _refreshHistory();
  }
  final StudioProject project;
  final ApprovedSourceProposal evidence;
  final RecordStorage records;
  final GenerationHost host;
  final CandidatePromotion publish;
  final void Function()? requireWorking;
  CandidateVerificationStore? _activeStore;
  Future<void> _stopWrite = Future<void>.value();
  bool _stopSaving = false;
  String? _stopSaveError, _stopHistoryError;
  Map<int, CandidateStopRequest> _stopRequests = const {};
  bool get stopRequestSaving => _stopSaving;
  String? get stopRequestSaveError => _stopSaveError;
  String? get stopRequestHistoryError => _stopHistoryError;
  CandidateStopRequest? stopRequestFor(CandidateVerificationRun run) {
    final request = _stopRequests[run.number];
    return request?.matches(project.id, run) == true ? request : null;
  }

  GeneratedProject? _unsavedObservation;
  Map<int, CandidateRecoveryAcknowledgement> _acknowledgements = const {};
  String? _acknowledgementHistoryError;
  String? get acknowledgementHistoryError => _acknowledgementHistoryError;
  CandidateRecoveryAcknowledgement? acknowledgementFor(
    CandidateVerificationRun run,
  ) {
    final value = _acknowledgements[run.number];
    return value?.matches(project.id, run) == true ? value : null;
  }

  List<CandidateVerificationRun> _history = const [];
  List<CandidateVerificationRun> get history => _history;
  String? _historyError;
  String? get historyError => _historyError;
  void _refreshHistory() {
    _stopRequests = const {};
    _stopHistoryError = null;
    _acknowledgements = const {};
    _acknowledgementHistoryError = null;
    try {
      final store = CandidateVerificationStore(records, project.id);
      _history = store.load().runs;
      final requests = <int, CandidateStopRequest>{};
      final acknowledgements = <int, CandidateRecoveryAcknowledgement>{};
      for (final run in _history) {
        try {
          final acknowledgement = store.acknowledgementFor(run);
          if (acknowledgement != null) {
            acknowledgements[run.number] = acknowledgement;
          }
        } catch (_) {
          _acknowledgementHistoryError = 'Saved recovery acknowledgement is unreadable. Retained records have not been replaced.';
        }
        try {
          final request = store.stopRequestFor(run);
          if (request != null) requests[run.number] = request;
        } catch (_) {
          _stopHistoryError = 'Saved Stop request evidence is unreadable. Retained records have not been replaced.';
        }
      }
      _stopRequests = Map.unmodifiable(requests);
      _acknowledgements = Map.unmodifiable(acknowledgements);
      _historyError = null;
      unawaited(_refreshReceipts(_history));
    } catch (_) {
      _historyError =
          'Saved candidate check history is unreadable. '
          'Verification is blocked; retained records have not been replaced.';
    }
  }

  Map<int, List<CandidateOperationReceipt>> _receiptHistory = const {};
  String? _receiptHistoryError;
  String? get receiptHistoryError => _receiptHistoryError;
  int _receiptEpoch = 0;
  bool _receiptsLoading = false, _receiptsReadable = false;

  CandidateRecoveryStatus? recoveryStatusFor(CandidateVerificationRun run) {
    if (!_history.any(
      (current) => CandidateRecoveryStatus.sameRun(current, run),
    )) {
      return null;
    }
    return CandidateRecoveryStatus.inspect(
      projectId: project.id,
      run: run,
      execution: savedExecutionFor(run),
      receipts: receiptsFor(run),
      stop: stopRequestFor(run),
      stopEvidenceUnavailable: _stopHistoryError != null,
      evidence: _historyError != null
          ? CandidateRecoveryEvidence.unavailable
          : _receiptsLoading
          ? CandidateRecoveryEvidence.loading
          : _receiptsReadable && _receiptHistoryError == null
          ? CandidateRecoveryEvidence.readable
          : CandidateRecoveryEvidence.unavailable,
    );
  }

  List<CandidateOperationReceipt> receiptsFor(CandidateVerificationRun run) =>
      _receiptHistory[run.number] ?? const [];

  Future<void> _refreshReceipts(List<CandidateVerificationRun> runs) async {
    final reader = host;
    final epoch = ++_receiptEpoch;
    _receiptHistory = const {};
    _receiptHistoryError = null;
    _receiptsReadable = false;
    _receiptsLoading = reader is CandidateReceiptHost;
    if (reader is! CandidateReceiptHost) return;
    final receiptReader = reader as CandidateReceiptHost;
    final found = <int, List<CandidateOperationReceipt>>{};
    try {
      for (final run in runs.where(
        (item) => item.snapshot.pendingOperation.isNotEmpty,
      )) {
        final receipts = await receiptReader.readCandidateReceipts(run);
        if (receipts.any(
          (receipt) => receipt.context.dispatchId != run.dispatchId,
        )) {
          throw const FormatException('Mismatched saved completion evidence.');
        }
        found[run.number] = List.unmodifiable(receipts);
      }
      if (!isDisposed && epoch == _receiptEpoch) {
        _receiptHistory = Map.unmodifiable(found);
        _receiptsLoading = false;
        _receiptsReadable = true;
        update();
      }
    } catch (_) {
      if (!isDisposed && epoch == _receiptEpoch) {
        _receiptsLoading = false;
        _receiptHistoryError = 'Saved native completion evidence is unavailable. The check journal is unchanged.';
        update();
      }
    }
  }

  /// Reads evidence only. Viewing a saved run never reconciles or replays it.
  AgentExecutionCheckpoint? savedExecutionFor(CandidateVerificationRun run) {
    final dispatchId = run.dispatchId;
    final storage = records;
    if (dispatchId == null || storage is! ConditionalRecordStorage) return null;
    try {
      final parts = dispatchId.split(':');
      final checkpoint = AgentExecutionCheckpointStore(storage)
          .load(parts.first);
      if (checkpoint == null ||
          checkpoint.revision < int.parse(parts.last) ||
          (checkpoint.requiresReconciliation &&
              checkpoint.dispatchId != dispatchId)) {
        return null;
      }
      return checkpoint;
    } catch (_) {
      return null;
    }
  }

  GeneratedProject _result;
  GeneratedProject get result => _result;
  bool _busy = false,
      _cancelled = false,
      _promoting = false,
      _transferred = false;
  bool get busy => _busy;
  bool get promoting => _promoting;
  bool get promoted => _transferred;
  String? _error;
  String? get error => _error;
  CandidateFailure? get failureDiagnosis =>
      CandidateFailure.inspect(_result, active: _busy || _transferred);
  Uri? _preview;
  Uri? get preview => _preview;

  void _authorize() {
    if (isDisposed || _cancelled) {
      throw StateError('Candidate operation stopped.');
    }
    if (!_result.confined) {
      throw StateError('Unconfined candidate refused.');
    }
    requireWorking?.call();
    ApprovedSourceProposer(records).requireCurrent(project, evidence);
    if (_result.approval == null ||
        !_result.approval!.matches(evidence.approval) ||
        !BuildPlan.parse(
          evidence.approval.content,
          board: RequirementsStore(records).load(project.id),
        ).matchesTasks(_result.tasks)) {
      throw StateError(
        'Candidate does not match the reviewed approval/task graph.',
      );
    }
    if (GenerationInput(
          project,
          ApplicationStore(records).load(project).definition,
        ).compare(_result) !=
        GeneratedSnapshotStatus.current) {
      throw StateError('Candidate inputs no longer match the current project.');
    }
  }

  bool get canPromote {
    if (_busy || _transferred || _result.phase != SourceGenerationPhase.ready) {
      return false;
    }
    try {
      _authorize();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _progress(GeneratedProject value) async {
    // Exit observations must survive a late Stop/withdrawal. Pending dispatch
    // checkpoints still require current authority before they can unblock work.
    final observation =
        value.steps.length > _result.steps.length ||
        value.phase == SourceGenerationPhase.failed;
    if (!observation) _authorize();
    if (observation && !isDisposed) _unsavedObservation = value;
    await _activeStore!.checkpoint(value, observation ? () {} : _authorize);
    _unsavedObservation = null;
    if (!isDisposed) {
      _result = value;
      _refreshHistory();
      update();
    }
    _authorize();
  }

  Future<void> verify({required bool approved}) async {
    if (!approved || _busy || _transferred || isDisposed) return;
    _busy = true;
    _cancelled = false;
    _stopSaveError = null;
    _stopWrite = Future<void>.value();
    _unsavedObservation = null;
    _error = null;
    update();
    var started = false;
    try {
      _authorize();
      final store = CandidateVerificationStore(records, project.id);
      _activeStore = store;
      final initial = _result.copy(
        phase: SourceGenerationPhase.verifying,
        checkpointVersion: 1,
        steps: [],
        outputs: {},
        pendingOperation: '',
        failedOperation: '',
      );
      final run = await store.start(initial, _authorize);
      started = true;
      _result = initial;
      if (host case final CandidateReceiptHost receiptHost) {
        await receiptHost.prepareCandidateReceipts(run, _authorize);
      }
      _authorize();
      _result = initial;
      _refreshHistory();
      _authorize();
      final verified = await host.verify(_result, _progress);
      _authorize();
      await store.checkpoint(verified, _authorize, finished: true);
      _authorize();
      _result = verified;
    } catch (_) {
      if (!isDisposed) {
        _error = _cancelled
            ? 'Candidate verification stopped after cancellation; working output retained. Check saved exits and runtime activity before retrying. Stopping the local request does not confirm server-side inference stopped.'
            : 'Candidate verification stopped; working output retained. Check local toolchain and file access, current Plan approval and saved exits before retrying.';
        _result = (_unsavedObservation ?? _result).copy(
          phase: SourceGenerationPhase.failed,
          error: _error!,
        );
        // Retain real completed evidence, but do not invent a command outcome.
        try {
          // Recording an observed stop grants no command or promotion authority.
          // CAS still prevents a superseded session from overwriting history.
          if (started) {
            await _activeStore?.checkpoint(
              _result,
              () {},
              finished: _result.pendingOperation.isEmpty,
            );
          }
        } catch (_) {
          _error = '$_error Candidate checkpoint could not be saved.';
        }
      }
    } finally {
      while (true) {
        final saving = _stopWrite;
        await saving;
        if (identical(saving, _stopWrite)) break;
      }
      _activeStore = null;
      if (!isDisposed) _refreshHistory();
      _busy = false;
      update();
    }
  }

  Future<void> acknowledgeStopped(CandidateVerificationRun expected) async {
    if (_busy || isDisposed) return;
    _busy = true;
    _cancelled = false;
    try {
      await CandidateVerificationStore(
        records,
        project.id,
      ).acknowledgeStopped(expected, _authorize);
      _error = null;
    } catch (_) {
      _error = 'Recovery could not be saved. Reopen the saved check history.';
    } finally {
      _busy = false;
      if (!isDisposed) _refreshHistory();
      update();
    }
  }

  void cancel() {
    if (!_busy || _promoting || isDisposed) return;
    final first = !_cancelled;
    _cancelled = true;
    final store = _activeStore;
    if (first && store != null) {
      _stopSaving = true;
      _stopWrite = _saveStopRequest(store, DateTime.now().toUtc());
    }
    // Signalling the owned runtime must not wait for storage to succeed.
    try {
      host.cancelVerification();
    } catch (_) {
      _error = 'Stop was requested, but local cancellation could not be signalled. Check runtime activity.';
    }
    update();
  }

  Future<void> _saveStopRequest(
    CandidateVerificationStore store,
    DateTime requestedAt,
  ) async {
    try {
      await store.requestStop(requestedAt);
    } catch (_) {
      _stopSaveError = 'The Stop request could not be saved. Check runtime activity and retained command evidence before retrying.';
    } finally {
      _stopSaving = false;
      if (!isDisposed) {
        _refreshHistory();
        update();
      }
    }
  }

  Future<bool> promote({required bool approved}) async {
    if (!approved || !canPromote || isDisposed) return false;
    _busy = true;
    _promoting = true;
    _error = null;
    update();
    try {
      _authorize();
      _preview = await publish(_result, host, _authorize);
      _transferred = true;
      return true;
    } catch (_) {
      if (!isDisposed) {
        _error = 'Promotion refused; working output retained. Check local preview and storage access and the current Plan approval, then retry promotion.';
      }
      return false;
    } finally {
      _promoting = false;
      if (isDisposed && !_transferred) {
        try {
          await host.dispose();
        } catch (_) {
          // The closed review cannot report cleanup failures. Do not let an
          // external host error escape or prevent releasing controller state.
        }
      }
      _busy = false;
      update();
    }
  }

  @override
  void dispose() {
    if (!_transferred) {
      host.cancelVerification();
      // Publication owns the host until its durable commit resolves.
      if (!_promoting) host.dispose().catchError((Object _) {});
    }
    super.dispose();
  }
}
