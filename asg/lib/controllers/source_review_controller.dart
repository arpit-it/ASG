import 'dart:async';

import '../models/approved_source_proposal.dart';
import '../models/build_plan.dart';
import '../models/project.dart';
import '../models/requirements_board.dart';
import '../models/source_edit_proposal.dart';
import '../models/source_generation.dart';
import '../services/approved_source_proposer.dart';
import '../services/model_settings_store.dart';
import '../services/plan_approval_store.dart';
import '../services/record_storage.dart';
import '../services/requirements_store.dart';
import '../services/source_review_snapshot.dart';
import 'base_controller.dart';

typedef SourceSnapshotReader = Future<Map<String, String>> Function(
  GeneratedProject project,
  List<String> paths,
);

/// Owns a read-only review session. No source writes or execution are exposed.
class SourceReviewController extends BaseController {
  SourceReviewController({
    required this.project,
    required this.generated,
    required this.records,
    ApprovedSourceProposer? proposer,
    SourceSnapshotReader? readSnapshot,
  }) : _proposer = proposer ?? ApprovedSourceProposer(records),
       _readSnapshot = readSnapshot ?? readSourceReviewSnapshot {
    refreshApproval();
  }

  final StudioProject project;
  final GeneratedProject generated;
  final RecordStorage records;
  final ApprovedSourceProposer _proposer;
  final SourceSnapshotReader _readSnapshot;
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
  bool get busy => _busy;
  String _status = '';
  String get status => _status;

  /// Retained proposals are hidden when their durable approval is no longer current.
  ApprovedSourceProposal? get proposal {
    final value = _proposal;
    if (value == null) return null;
    try {
      _proposer.requireCurrent(project, value);
      return value;
    } catch (_) {
      return null;
    }
  }

  bool get stale => _proposal != null && proposal == null;

  void refreshApproval() {
    if (_busy || isDisposed) return;
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
    if (_busy || isDisposed) return;
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
    _proposal = null;
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
    _cancelled = true;
    unawaited(_proposer.cancel().catchError((Object _) {}));
    super.dispose();
  }
}
