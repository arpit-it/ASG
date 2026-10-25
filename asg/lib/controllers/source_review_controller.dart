import 'dart:async';

import '../models/approved_source_proposal.dart';
import '../models/build_plan.dart';
import '../models/project.dart';
import '../models/requirements_board.dart';
import '../models/source_edit_proposal.dart';
import '../models/source_generation.dart';
import '../services/approved_source_proposer.dart';
import '../services/model_settings_store.dart';
import '../services/folder_picker.dart';
import '../services/generation_host.dart';
import '../services/generation_host_factory.dart';
import 'source_candidate_controller.dart';
import '../services/source_candidate.dart';
import '../services/plan_approval_store.dart';
import '../services/record_storage.dart';
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
    _workingRecord = records.getString('studio.generation.v1.${project.id}');
    refreshApproval();
  }

  late final String? _workingRecord;
  void _requireWorking() {
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
  void _sessionChanged() => update();
  bool get candidateSupported => _folderPicker.supported;
  String? _candidateParent;
  String? get candidateParent => _candidateParent;
  GeneratedProject? _candidate;
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
    } catch (error) {
      if (!isDisposed) _error = 'Folder selection failed. $error';
    } finally {
      _busy = false;
      update();
    }
  }

  Future<void> prepareCandidate() async {
    if (busy || isDisposed) return;
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
        if (_cancelled || isDisposed) {
          throw StateError('Candidate preparation cancelled.');
        }
        _requireWorking();
        _proposer.requireCurrent(project, evidence);
      }

      final value = await _prepareCandidate(
        project: project,
        generated: generated,
        evidence: evidence,
        records: records,
        parent: parent,
        checkActive: checkActive,
      );
      // Retain the path even if cancellation/withdrawal follows the last write.
      if (!isDisposed) _candidate = value;
      checkActive();
      if (publishCandidate != null) {
        _candidateSession?.removeListener(_sessionChanged);
        _candidateSession?.dispose();
        _candidateSession = SourceCandidateController(
          project: project,
          candidate: value,
          evidence: evidence,
          records: records,
          host: _createCandidateHost(),
          publish: publishCandidate!,
          requireWorking: _requireWorking,
        );
        _candidateSession!.addListener(_sessionChanged);
      }
      _candidateParent = null;
      _status =
          'Unverified candidate prepared. Working source and preview retained.';
    } catch (error) {
      if (!isDisposed) {
        _error = 'Candidate preparation did not complete. $error';
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
  bool get busy => _busy || (_candidateSession?.busy ?? false);
  String _status = '';
  String get status => _status;

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

  void refreshApproval() {
    if (busy || isDisposed) return;
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
    } catch (error) {
      _tasks = const [];
      _error = 'Source review is unavailable. $error';
    }
    update();
  }

  Future<void> request(String taskId, List<String> selected) async {
    if (busy || promoted || isDisposed) return;
    refreshApproval();
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
    final started = PlanApprovalStore(records).requireCurrentApproval(project);
    _busy = true;
    _cancelled = false;
    _candidateSession?.removeListener(_sessionChanged);
    _candidateSession?.dispose();
    _candidateSession = null;
    _proposal = null;
    _candidateParent = null;
    _error = null;
    _status = 'Reading recorded source…';
    update();
    try {
      final originals = await _readSnapshot(generated, selection);
      if (_cancelled || isDisposed) return;
      final current = PlanApprovalStore(records)
          .requireCurrentApproval(project);
      if (!started.matches(current)) {
        throw StateError('Plan approval changed while reading source.');
      }
      _status = 'Requesting local model proposal…';
      update();
      final value = await _proposer.propose(
        project: project,
        boardTaskId: taskId,
        config: ModelSettingsStore(records).load(),
        originals: originals,
      );
      if (_cancelled || isDisposed) return;
      _proposer.requireCurrent(project, value);
      _proposal = value;
      _status = 'Proposal ready for review. No files changed.';
    } catch (error) {
      if (!isDisposed && !_cancelled) _error = 'Source proposal failed. $error';
    } finally {
      _busy = false;
      if (_cancelled) _status = 'Review cancelled. No files changed.';
      update();
    }
  }

  Future<void> cancel() async {
    if (_candidateSession?.busy ?? false) {
      _candidateSession!.cancel();
      return;
    }
    if (!_busy || _cancelled || isDisposed) return;
    _cancelled = true;
    _status = 'Cancelling review…';
    update();
    try {
      await _proposer.cancel();
    } catch (error) {
      if (!isDisposed) _error = 'Model transport cleanup failed. $error';
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
