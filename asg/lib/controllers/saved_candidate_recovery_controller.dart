// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/agent_session.dart';
import '../models/agent_session_binding.dart';
import '../models/approved_source_proposal.dart';
import '../models/candidate_reopen_context.dart';
import '../models/project.dart';
import '../services/application_store.dart';
import '../services/candidate_reopen_context_store.dart';
import '../services/candidate_verification_store.dart';
import '../services/generation_host.dart';
import '../services/generation_host_factory.dart';
import '../services/record_storage.dart';
import '../services/source_generation_store.dart';
import 'base_controller.dart';
import 'source_candidate_controller.dart';
import 'source_generation_controller.dart';

/// Owns two fresh hosts. Opening inspects retained source only; existing candidate
/// controls keep acknowledgment, verification and promotion as separate actions.
class SavedCandidateRecoveryController extends BaseController {
  SavedCandidateRecoveryController({
    required this.project,
    required this.records,
    required this.selectedSession,
    required this.runNumber,
    GenerationHost Function()? createHost,
  }) : _createHost = createHost ?? createGenerationHost;
  final StudioProject project;
  final ConditionalRecordStorage records;
  final AgentSession selectedSession;
  final int runNumber;
  // An injected factory must return distinct, newly owned hosts.
  final GenerationHost Function() _createHost;
  bool _busy = false;
  String? _error;
  int _epoch = 0;
  CandidateReopenContext? _context;
  CandidateReopenBasis? _basis;
  ApprovedSourceProposal? _evidence;
  SourceGenerationController? _working;
  SourceCandidateController? _candidate;
  bool get busy => _busy;
  String? get error => _error;
  CandidateReopenContext? get context => _context;
  ApprovedSourceProposal? get evidence => _evidence;
  SourceCandidateController? get candidate => _candidate;
  bool get canLeave => !(_candidate?.busy ?? false);
  bool get actionsEnabled {
    if (_busy || isDisposed || _candidate == null || _candidate!.promoted) {
      return false;
    }
    try {
      _requireCurrent();
      return true;
    } catch (_) {
      return false;
    }
  }

  String? get actionError =>
      _candidate != null && !_candidate!.promoted && !actionsEnabled && !_busy
      ? 'Recovery actions are unavailable. Approval, session, source context or working build changed. Existing history is retained.'
      : null;

  CandidateReopenContextStore get _store =>
      CandidateReopenContextStore(records, project);
  void _requireCurrent() {
    final origin = _context;
    final basis = _basis;
    if (isDisposed ||
        origin == null ||
        basis == null ||
        records.getString(origin.storageKey) != jsonEncode(origin.toJson())) {
      throw StateError('Saved candidate context changed.');
    }
    final session = _candidate?.sessionBinding?.session ?? origin.session;
    final current = _store.loadLatest(
      session,
      session.dispatches.last.runNumber,
    );
    if (jsonEncode(current.basis.toJson()) != jsonEncode(basis.toJson())) {
      throw StateError('Prepared candidate evidence changed.');
    }
  }

  Future<void> open() async {
    if (_busy || isDisposed || _candidate != null) return;
    final epoch = ++_epoch;
    _busy = true;
    _error = null;
    update();
    GenerationHost? workingHost, candidateHost;
    SourceGenerationController? working;
    SourceCandidateController? candidate;
    var adopted = false;
    var unsupported = false;
    try {
      final context = _store.loadLatest(selectedSession, runNumber);
      final basis = context.basis;
      final run = CandidateVerificationStore(
        records,
        project.id,
      ).load().runs.last;
      workingHost = _createHost();
      candidateHost = _createHost();
      if (identical(workingHost, candidateHost) ||
          !workingHost.supported ||
          !candidateHost.supported ||
          workingHost is! CandidateSourceInspectionHost ||
          candidateHost is! CandidateSourceInspectionHost) {
        unsupported = true;
        throw UnsupportedError(
          'Read-only candidate source inspection is unavailable on this host.',
        );
      }
      await (workingHost as CandidateSourceInspectionHost).checkSources(
        basis.working,
      );
      if (isDisposed || epoch != _epoch) return;
      await (candidateHost as CandidateSourceInspectionHost).checkSources(
        run.snapshot,
      );
      if (isDisposed || epoch != _epoch) return;
      _store.requireUnchanged(context);
      final before = AgentSession.fromJson({
        ...context.session.toJson(),
        'revision': context.session.revision - 1,
        'dispatches': context.session.dispatches
            .take(context.session.dispatches.length - 1)
            .map((ref) => ref.toJson())
            .toList(),
      });
      working = SourceGenerationController(
        project: project,
        definition: ApplicationStore(records).load(project).definition,
        store: SourceGenerationStore(records),
        host: workingHost,
        selectedSession: before,
      );
      if (!working.available || working.error != null) {
        throw StateError('Working build is unavailable.');
      }
      final binding = AgentSessionBinding.select(
        session: before,
        projectId: project.id,
        boardTaskId: basis.evidence.boardTaskId,
      ).admitted(context.session, context.dispatchId);
      _context = context;
      _basis = basis;
      _evidence = basis.evidence;
      final publisher = working;
      candidate = SourceCandidateController(
        project: project,
        candidate: run.snapshot,
        evidence: _evidence!,
        records: records,
        host: candidateHost,
        reopenBasis: basis,
        sessionBinding: binding,
        requireWorking: _requireCurrent,
        publish: (value, host, authorize) => publisher.promoteCandidate(
          value,
          host,
          authorize,
          expectedWorking: basis.working,
        ),
      );
      _working = working;
      _candidate = candidate;
      working.addListener(_changed);
      candidate.addListener(_changed);
      adopted = true;
    } catch (_) {
      if (!isDisposed && epoch == _epoch) {
        _error = unsupported
            ? 'Saved candidate recovery is unavailable on this host. Read-only native source inspection is required; saved history is retained.'
            : 'Saved candidate could not be opened. Check the current session, Plan, source and working build. Missing legacy context is not recreated; existing records are retained.';
      }
    } finally {
      if (!adopted) {
        if (candidate != null) {
          candidate.dispose();
        } else {
          await _disposeHost(candidateHost);
        }
        if (working != null) {
          working.dispose();
        } else if (!identical(workingHost, candidateHost)) {
          await _disposeHost(workingHost);
        }
        if (!isDisposed) {
          _working = null;
          _candidate = null;
          _context = null;
          _basis = null;
          _evidence = null;
        }
      }
      if (!isDisposed && epoch == _epoch) {
        _busy = false;
        update();
      }
    }
  }

  static Future<void> _disposeHost(GenerationHost? host) async {
    try {
      await host?.dispose();
    } catch (_) {
      /* Cleanup failure grants no authority. */
    }
  }

  void _changed() => update();
  @override
  void dispose() {
    _epoch++;
    _candidate?.removeListener(_changed);
    _working?.removeListener(_changed);
    _candidate?.dispose();
    _working?.dispose();
    super.dispose();
  }
}
