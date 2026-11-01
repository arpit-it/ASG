// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import '../models/approved_source_proposal.dart';
import '../models/build_plan.dart';
import '../models/project.dart';
import '../models/plan_approval.dart';
import '../models/repair_attempt.dart';
import '../models/requirements_board.dart';
import '../models/source_edit_proposal.dart';
import '../models/source_generation.dart';
import '../services/approved_source_proposer.dart';
import '../services/candidate_repair_evidence.dart';
import '../services/model_settings_store.dart';
import '../services/folder_picker.dart';
import '../services/generation_host.dart';
import '../services/generation_host_factory.dart';
import 'source_candidate_controller.dart';
import '../services/source_candidate.dart';
import '../services/plan_approval_store.dart';
import '../services/record_storage.dart';
import '../services/repair_attempt_store.dart';
import '../services/requirements_store.dart';
import '../services/source_review_snapshot.dart';
import 'base_controller.dart';

typedef SourceSnapshotReader = Future<Map<String, String>> Function(
  GeneratedProject project,
  List<String> paths,
);

typedef SourceCandidatePreparer = Future<GeneratedProject> Function({
  required StudioProject project,
  required GeneratedProject generated,
  required ApprovedSourceProposal evidence,
  required RecordStorage records,
  required String parent,
  required void Function() checkActive,
});

/// Owns proposal review and explicitly consented, unverified candidate copies.
class SourceReviewController extends BaseController {
  SourceReviewController({
    required this.project,
    required this.generated,
    required this.records,
    ApprovedSourceProposer? proposer,
    SourceSnapshotReader? readSnapshot,
    SourceCandidatePreparer? prepareCandidate,
    FolderPicker? folderPicker,
    this.publishCandidate,
    GenerationHost Function()? createCandidateHost,
  }) : _proposer = proposer ?? ApprovedSourceProposer(records),
       _readSnapshot = readSnapshot ?? readSourceReviewSnapshot,
       _prepareCandidate = prepareCandidate ?? prepareSourceCandidate,
       _folderPicker = folderPicker ?? FolderPicker(),
       _createCandidateHost = createCandidateHost ?? createGenerationHost {
    try {
      _workingRecord = records.getString('studio.generation.v1.${project.id}');
      _workingRecordReadable = true;
    } catch (_) {
      _workingRecordReadable = false;
    }
    refreshApproval();
  }

  late final String? _workingRecord;
  late final bool _workingRecordReadable;
  static const _workingReadError =
      'The working build record could not be read. Restore local storage access, '
      'then close and reopen source review. Saved records and working output '
      'have not been replaced.';
  void _requireWorking() {
    if (!_workingRecordReadable) throw StateError(_workingReadError);
    if (records.getString('studio.generation.v1.${project.id}') !=
        _workingRecord) {
      throw StateError(
        'Working build changed. Return to Build and reopen source review.',
      );
    }
  }

  bool get promoted => _candidateSession?.promoted ?? false;
  final StudioProject project;
  final GeneratedProject generated;
  final RecordStorage records;
  final ApprovedSourceProposer _proposer;
  final SourceSnapshotReader _readSnapshot;
  final SourceCandidatePreparer _prepareCandidate;
  final FolderPicker _folderPicker;
  final CandidatePromotion? publishCandidate;
  final GenerationHost Function() _createCandidateHost;
  SourceCandidateController? _candidateSession;
  SourceCandidateController? get candidateSession => _candidateSession;
  void _sessionChanged() {
    // A new candidate action supersedes the preceding review cancellation.
    if (!_repairLoopActive && !_busy && (_candidateSession?.busy ?? false)) {
      _cancelled = false;
    }
    update();
  }

  bool get candidateSupported => _folderPicker.supported;
  String? _candidateParent;
  String? get candidateParent => _candidateParent;
  GeneratedProject? _candidate;
  GeneratedProject? _proposalSource;
  GeneratedProject? get candidate => _candidateSession?.result ?? _candidate;

  Future<void> selectCandidateParent() async {
    if (busy || isDisposed || !candidateSupported || proposal == null) return;
    _busy = true;
    _error = null;
    update();
    try {
      final parent = await _folderPicker.pick();
      if (!isDisposed && proposal != null && parent != null) {
        _candidateParent = parent;
      }
    } catch (_) {
      if (!isDisposed) _error = 'Folder selection failed. Try the folder picker again and check local file access.';
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> prepareCandidate() => _prepareReviewedCandidate();

  bool get canApplyRepair =>
      !busy &&
      !promoted &&
      !isDisposed &&
      publishCandidate != null &&
      candidateSupported &&
      _candidateParent != null &&
      proposal?.repairRun != null;

  /// Consent covers this reviewed diff and one confined check-graph rerun only.
  Future<void> applyReviewedRepair({required bool approved}) async {
    if (!approved || !canApplyRepair) return;
    await _prepareReviewedCandidate(verifyRepair: true);
  }

  Future<void> _prepareReviewedCandidate({
    bool verifyRepair = false,
    bool automatic = false,
  }) async {
    if (_busy ||
        (_candidateSession?.busy ?? false) ||
        (_repairLoopActive && !automatic) ||
        isDisposed) {
      return;
    }
    final evidence = proposal;
    final parent = _candidateParent;
    if (evidence == null || parent == null) {
      _error = 'Review a current proposal and select a candidate folder first.';
      update();
      return;
    }
    _busy = true;
    _cancelled = false;
    _error = null;
    _status = 'Preparing separate unverified source candidate…';
    update();
    try {
      void checkActive() {
        if (_cancelled || _loopCancelled || isDisposed) {
          throw StateError('Candidate preparation cancelled.');
        }
        _requireWorking();
        _proposer.requireCurrent(project, evidence);
      }

      final value = await _prepareCandidate(
        project: project,
        generated: _proposalSource ?? generated,
        evidence: evidence,
        records: records,
        parent: parent,
        checkActive: checkActive,
      );
      // Retain the path even if cancellation/withdrawal follows the last write.
      if (!isDisposed) _candidate = value;
      checkActive();
      // The reviewed diff has now been captured in a separate candidate. Its
      // subsequent check journal replaces latest-failure evidence intentionally.
      final candidateEvidence = ApprovedSourceProposal(
        projectId: evidence.projectId,
        boardTaskId: evidence.boardTaskId,
        approval: evidence.approval,
        proposal: evidence.proposal,
        modelRequest: evidence.modelRequest,
      );
      _proposal = candidateEvidence;
      if (publishCandidate != null) {
        _candidateSession?.removeListener(_sessionChanged);
        _candidateSession?.dispose();
        _candidateSession = SourceCandidateController(
          project: project,
          candidate: value,
          evidence: candidateEvidence,
          records: records,
          host: _createCandidateHost(),
          publish: publishCandidate!,
          requireWorking: () {
            if (_repairLoopActive && _loopCancelled) {
              throw StateError('Automatic repair stopped.');
            }
            _requireWorking();
          },
        );
        _candidateSession!.addListener(_sessionChanged);
      }
      _candidateParent = null;
      _status =
          'Unverified candidate prepared. Working source and preview retained.';
      if (verifyRepair) {
        // Keep the parent operation busy across the copy/dispatch boundary.
        // Preparation consumed the failure binding; the session now guards the
        // copied approval, inputs and working record before each actual check.
        void checkActiveAfterCopy() {
          if (_cancelled || _loopCancelled || isDisposed) {
            throw StateError('Repair verification cancelled.');
          }
          _requireWorking();
          _proposer.requireCurrent(project, candidateEvidence);
        }

        checkActiveAfterCopy();
        _status = 'Verifying repaired candidate; working output retained.';
        update();
        // Listeners may cancel, withdraw approval or dispose during progress.
        checkActiveAfterCopy();
        await _candidateSession!.verify(approved: true);
        if (!isDisposed) {
          _status =
              _candidateSession!.result.phase == SourceGenerationPhase.ready
              ? 'Repaired candidate checks passed. Explicit promotion is required.'
              : 'Repaired candidate checks stopped; inspect saved exits. Working output retained.';
        }
      }
    } catch (_) {
      if (!isDisposed) {
        _error = 'Candidate preparation did not complete. Check local file access and the current Plan approval, then retry. Inspect the selected folder for any partial copy; working output is retained.';
        _status = 'Candidate preparation failed; working output retained.';
      }
    } finally {
      _busy = false;
      if (_cancelled) {
        _status = 'Preparation cancelled; inspect any retained candidate path.';
      }
      update();
    }
  }

  List<DevelopmentTask> _tasks = const [];
  List<DevelopmentTask> get tasks => _tasks;
  List<String> get paths => List.unmodifiable(
    generated.sources.keys.where(SourceEditProposal.isSourcePath).toList()
      ..sort(),
  );
  ApprovedSourceProposal? _proposal;
  String? _error;
  String? get error => _error;
  bool _busy = false, _cancelled = false;
  bool get reviewBusy => _busy;
  bool _repairLoopActive = false, _loopCancelled = false;
  bool get automaticRepairActive => _repairLoopActive;
  bool get busy =>
      _repairLoopActive || _busy || (_candidateSession?.busy ?? false);
  String _status = '';
  String get status {
    final session = _candidateSession;
    if (session == null || _repairLoopActive || _busy || _cancelled) {
      return _status;
    }
    if (proposal?.repairRun != null && !session.busy) return _status;
    if (session.promoted) {
      return 'Candidate promoted. Working source and preview now use the verified candidate.';
    }
    if (session.promoting) {
      return 'Validating preview and publishing the verified candidate…';
    }
    if (session.busy) {
      return 'Verifying isolated candidate. Working source and preview retained.';
    }
    if (session.result.phase == SourceGenerationPhase.ready) {
      return 'Candidate verified. Explicit promotion is required to change working output.';
    }
    if (session.result.phase == SourceGenerationPhase.failed) {
      return 'Candidate checks stopped. Working source and preview retained.';
    }
    return _status;
  }

  /// Retained proposals are hidden when their durable approval is no longer current.
  ApprovedSourceProposal? get proposal {
    final value = _proposal;
    if (value == null) return null;
    try {
      _requireWorking();
      _proposer.requireCurrent(project, value);
      return value;
    } catch (_) {
      return null;
    }
  }

  bool get stale => !promoted && _proposal != null && proposal == null;

  List<RepairAttempt> get repairHistory {
    try {
      return RepairAttemptStore(records, project.id).load().attempts;
    } catch (_) {
      return const [];
    }
  }

  String? get repairHistoryError {
    try {
      RepairAttemptStore(records, project.id).load();
      return null;
    } catch (_) {
      return 'Saved repair history is unreadable. Repair requests are blocked; '
          'retained records have not been replaced.';
    }
  }

  bool repairUsesCurrentApproval(RepairAttempt attempt) {
    try {
      return attempt.failure.snapshot.approval!.matches(
        PlanApprovalStore(records).requireCurrentApproval(project),
      );
    } catch (_) {
      return false;
    }
  }

  Map<String, int> get repairUsage => Map.unmodifiable({
    for (final category in ['analyze', 'test', 'build'])
      category: repairHistory
          .where(
            (attempt) =>
                attempt.category == category &&
                repairUsesCurrentApproval(attempt),
          )
          .length,
  });

  /// A saved source failure can remain inspectable after its budget is spent.
  bool get hasRepairFailure => !busy && _hasRepairFailure;

  bool get _hasRepairFailure {
    final session = _candidateSession;
    if (_busy ||
        (session?.busy ?? false) ||
        promoted ||
        isDisposed ||
        session == null ||
        proposal == null) {
      return false;
    }
    try {
      requireRepairFailure(records, project.id, session.result);
      return true;
    } catch (_) {
      return false;
    }
  }

  String? get repairBlockedReason {
    final historyError = repairHistoryError;
    if (historyError != null) return historyError;
    if (!_hasRepairFailure) return null;
    final category = _candidateSession!.result.steps.last.operation;
    if ((repairUsage[category] ?? 0) >= 3) {
      return 'Repair budget exhausted: $category has used all 3 requests for '
          'this approval. Inspect saved attempts; no further request will start.';
    }
    return null;
  }

  bool get canRequestRepair => hasRepairFailure && repairBlockedReason == null;

  Future<void> requestRepair(List<String> selected) async {
    if (!canRequestRepair) {
      if (!busy && !isDisposed && repairBlockedReason != null) {
        _error = repairBlockedReason;
        update();
      }
      return;
    }
    await request(proposal!.boardTaskId, selected, repair: true);
  }

  bool get canStartAutomaticRepair =>
      canRequestRepair &&
      candidateSupported &&
      publishCandidate != null &&
      _candidateParent != null;

  /// Explicit consent covers selected paths, separate copies and confined checks.
  /// Durable category budgets also bound restarted sessions; never auto-promotes.
  Future<void> runAutomaticRepairs(
    List<String> selected, {
    required bool approved,
  }) async {
    if (!approved || !canStartAutomaticRepair) return;
    final parent = _candidateParent!;
    final selection = List<String>.unmodifiable(selected);
    final approval = proposal!.approval;
    final taskId = proposal!.boardTaskId;
    _repairLoopActive = true;
    _loopCancelled = false;
    _cancelled = false;
    _error = null;
    void authorize() {
      if (_loopCancelled || isDisposed) {
        throw StateError('Automatic repair stopped.');
      }
      _requireWorking();
      if (!approval.matches(
        PlanApprovalStore(records).requireCurrentApproval(project),
      )) {
        throw StateError('Automatic repair approval changed.');
      }
    }

    try {
      // Three supported categories, each with at most three durable reservations.
      // The extra bound prevents a non-progressing integration from looping.
      for (var iteration = 0; iteration < 9; iteration++) {
        authorize();
        final blocked = repairBlockedReason;
        if (blocked != null) throw StateError(blocked);
        if (!_hasRepairFailure) {
          throw StateError('No current repairable saved failure.');
        }
        final previousProposal = _proposal;
        await _request(taskId, selection, repair: true, automatic: true);
        authorize();
        if (_error != null ||
            identical(_proposal, previousProposal) ||
            proposal?.repairRun == null) {
          throw StateError(_error ?? 'Repair produced no current proposal.');
        }
        _candidateParent = parent;
        await _prepareReviewedCandidate(verifyRepair: true, automatic: true);
        authorize();
        final session = _candidateSession;
        if (_error != null || session == null || session.error != null) {
          throw StateError(
            _error ?? session?.error ?? 'Candidate verification unavailable.',
          );
        }
        if (session.result.phase == SourceGenerationPhase.ready) {
          _status =
              'Automatic repair checks passed. Explicit promotion is required.';
          return;
        }
      }
      throw StateError(
        'Automatic repair session limit reached. Inspect saved attempts.',
      );
    } catch (_) {
      if (!isDisposed) {
        _error = _loopCancelled ? null : repairBlockedReason ?? 'Automatic repair stopped. Check the current Plan approval and local model connection, then inspect saved attempts and exits before retrying. Working output is retained.';
        _status = _loopCancelled
            ? 'Automatic repair cancelled; working output retained.'
            : 'Automatic repair stopped; inspect saved attempts and exits. Working output retained.';
      }
    } finally {
      _repairLoopActive = false;
      _loopCancelled = false;
      update();
    }
  }

  void refreshApproval() {
    if (busy || isDisposed) return;
    if (!_workingRecordReadable) {
      _tasks = const [];
      _error = _workingReadError;
      update();
      return;
    }
    try {
      final approval = PlanApprovalStore(records)
          .requireCurrentApproval(project);
      final board = RequirementsStore(records).load(project.id);
      final plan = BuildPlan.parse(approval.content, board: board);
      final ids = plan.tasks.map((task) => task.boardTaskId).toSet();
      _tasks = List.unmodifiable(
        board.tasks.where((task) => ids.contains(task.id)),
      );
      if (_tasks.isEmpty) {
        throw StateError('Approve a Plan mapped to saved board tasks first.');
      }
      _error = null;
    } catch (_) {
      _tasks = const [];
      _error = 'Source review is unavailable. Reopen Build and approve a current Plan mapped to saved tasks. If saved records cannot be read, restore valid local records before retrying.';
    }
    update();
  }

  Future<void> request(
    String taskId,
    List<String> selected, {
    bool repair = false,
  }) => _request(taskId, selected, repair: repair);

  Future<void> _request(
    String taskId,
    List<String> selected, {
    bool repair = false,
    bool automatic = false,
  }) async {
    if (_busy ||
        (_candidateSession?.busy ?? false) ||
        (_repairLoopActive && !automatic) ||
        promoted ||
        isDisposed) {
      return;
    }
    final repairCandidate = repair ? _candidateSession?.result : null;
    if (repair && (!_hasRepairFailure || repairBlockedReason != null)) return;
    refreshApproval();
    if (isDisposed || _error != null) return;
    if (!_tasks.any((task) => task.id == taskId)) {
      _error = 'Select a task in the current approved Plan.';
      update();
      return;
    }
    final selection = List<String>.unmodifiable(selected);
    if (selection.isEmpty ||
        selection.length > SourceEditProposal.maxFiles ||
        selection.toSet().length != selection.length ||
        selection.any((value) => !paths.contains(value))) {
      _error = 'Select 1–8 distinct recorded Dart files.';
      update();
      return;
    }
    // Bind the entire request, including asynchronous source capture, to approval.
    late final PlanApproval started;
    try {
      _requireWorking();
      started = PlanApprovalStore(records).requireCurrentApproval(project);
    } catch (_) {
      if (!isDisposed) {
        _error = 'Source review approval could not be read. Restore local storage access and approve a current Plan before retrying. Working output is retained.';
        update();
      }
      return;
    }
    _busy = true;
    _cancelled = false;
    if (!repair) {
      _candidateSession?.removeListener(_sessionChanged);
      _candidateSession?.dispose();
      _candidateSession = null;
    }
    if (!repair) _proposal = null;
    _candidateParent = null;
    _error = null;
    _status = 'Reading recorded source…';
    update();
    try {
      void authorizeRequest() {
        if (_cancelled || _loopCancelled || isDisposed) {
          throw StateError('Source proposal cancelled.');
        }
        _requireWorking();
        final current = PlanApprovalStore(records)
            .requireCurrentApproval(project);
        if (!started.matches(current)) {
          throw StateError('Plan approval changed while reading source.');
        }
      }

      // Progress listeners can Stop, dispose or change durable inputs. Check
      // again after notifying them, before starting capture or inference.
      authorizeRequest();
      final failure = repairCandidate == null
          ? null
          : requireRepairFailure(records, project.id, repairCandidate);
      final source = repairCandidate ?? generated;
      final originals = await _readSnapshot(source, selection);
      authorizeRequest();
      if (failure != null) {
        requireRepairFailure(records, project.id, source, expected: failure);
      }
      _status = 'Requesting local model proposal…';
      update();
      authorizeRequest();
      final value = await _proposer.propose(
        project: project,
        boardTaskId: taskId,
        config: ModelSettingsStore(records).load(),
        originals: originals,
        repairCandidate: repairCandidate,
      );
      if (_cancelled || isDisposed) return;
      _proposer.requireCurrent(project, value);
      _requireWorking();
      _proposal = value;
      _proposalSource = source;
      _status = 'Proposal ready for review. No files changed.';
    } catch (_) {
      if (!isDisposed && !_cancelled) {
        _error = 'Source proposal failed. Check the local model connection, recorded source access and current Plan approval, then request a new proposal. Working output is retained.';
        _status = 'Source proposal failed. Previous candidate and working output retained.';
      }
    } finally {
      _busy = false;
      if (_cancelled) _status = 'Review cancelled. No files changed.';
      update();
    }
  }

  Future<void> cancel() async {
    if (_repairLoopActive) {
      _loopCancelled = true;
    }
    if (_candidateSession?.busy ?? false) {
      if (_repairLoopActive) _cancelled = true;
      _candidateSession!.cancel();
      return;
    }
    if (!_busy || _cancelled || isDisposed) {
      if (_repairLoopActive) _cancelled = true;
      return;
    }
    _cancelled = true;
    _status = 'Cancelling review…';
    update();
    try {
      await _proposer.cancel();
    } catch (_) {
      if (!isDisposed) _error = 'Model transport cleanup failed. The review result will be ignored; check runtime activity before retrying. Stopping the local request does not confirm server-side inference stopped.';
    }
  }

  @override
  void dispose() {
    _candidateSession?.removeListener(_sessionChanged);
    _candidateSession?.dispose();
    _cancelled = true;
    unawaited(_proposer.cancel().catchError((Object _) {}));
    super.dispose();
  }
}
