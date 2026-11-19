// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/agent_session.dart';
import '../models/agent_session_run_status.dart';
import '../services/agent_session_run_status_store.dart';
import '../models/agent_session_binding.dart';
import '../services/agent_session_admission.dart';
import '../models/build_plan.dart';
import '../models/requirements_board.dart';
import '../services/agent_session_store.dart';
import '../services/plan_approval_store.dart';
import '../services/requirements_store.dart';
import 'base_controller.dart';
import 'published_task_evidence_controller.dart';
import '../services/published_task_evidence_store.dart';
import 'saved_candidate_recovery_controller.dart';
import '../services/candidate_reopen_context_store.dart';
import '../services/generation_host.dart';

/// Manages saved observations only; no command/model service is owned here.
final class AgentSessionController extends BaseController {
  AgentSessionController(
    this.store, {
    String Function()? createSessionId,
    AgentSessionRunStatusStore? runStatusStore,
    this.createRecoveryHost,
  }) : _createSessionId = createSessionId ?? _newId,
       _runStatusStore =
           runStatusStore ??
           AgentSessionRunStatusStore(store.records, store.project.id);
  static String _newId() => 'session-${DateTime.now().microsecondsSinceEpoch}';
  final AgentSessionStore store;
  final GenerationHost Function()? createRecoveryHost;
  final AgentSessionRunStatusStore _runStatusStore;
  List<AgentSessionRunStatus> _runStatuses = const [];
  List<AgentSessionRunStatus> get runStatuses => _runStatuses;
  final String Function() _createSessionId;
  List<AgentSession> _sessions = const [];
  List<String> _ids = const [], _unavailableIds = const [];
  List<DevelopmentTask> _tasks = const [];
  Set<String> _selectedTaskIds = const {};
  AgentSession? _selected;
  bool _busy = false;
  String? _error, _historyError, _approvalError;
  List<AgentSession> get sessions => _sessions;
  List<String> get unavailableIds => _unavailableIds;
  List<DevelopmentTask> get tasks => _tasks;
  Set<String> get selectedTaskIds => _selectedTaskIds;
  AgentSession? get selected => _selected;
  bool get busy => _busy;
  String? get error => _error;
  String? get historyError => _historyError;
  String? get approvalError => _approvalError;
  bool get sessionLimitReached =>
      _ids.length >= AgentSessionCatalog.maxSessions;
  bool get canCreate =>
      !_busy &&
      !isDisposed &&
      _historyError == null &&
      _approvalError == null &&
      !sessionLimitReached &&
      _selectedTaskIds.isNotEmpty;
  bool get canRemember =>
      !_busy &&
      !isDisposed &&
      _historyError == null &&
      !sessionLimitReached &&
      _selected != null &&
      !_ids.contains(_selected!.sessionId);

  void load() {
    if (_busy || isDisposed) return;
    _error = null;
    _refresh(resetSelection: true);
    update();
  }

  void _refresh({bool resetSelection = false}) {
    final sessions = <AgentSession>[], unavailable = <String>[];
    _historyError = null;
    try {
      _ids = List.unmodifiable(store.sessionIds());
      for (final id in _ids) {
        try {
          final value = store.load(id);
          if (value == null) {
            unavailable.add(id);
          } else {
            sessions.add(value);
          }
        } catch (_) {
          unavailable.add(id);
        }
      }
    } catch (_) {
      _ids = const [];
      _historyError = 'Saved session list is unavailable. Existing records are retained. You can still open a session by its ID.';
    }
    _sessions = List.unmodifiable(sessions);
    _unavailableIds = List.unmodifiable(unavailable);
    if (_selected case final previous?) {
      try {
        final current = store.load(previous.sessionId);
        if (current == null) throw StateError('Selected session missing');
        _selected = current;
      } catch (_) {
        _error = 'Selected session could not be refreshed. Its last visible snapshot is retained.';
      }
    }
    _refreshRunStatuses();
    _approvalError = null;
    try {
      final approval = PlanApprovalStore(store.records)
          .requireCurrentApproval(store.project);
      final board = RequirementsStore(store.records).load(store.project.id);
      final plan = BuildPlan.parse(approval.content, board: board);
      _tasks = List.unmodifiable(
        board.tasks.where(
          (task) => plan.tasks.any((mapped) => mapped.boardTaskId == task.id),
        ),
      );
      AgentSessionTasks.fromBoardTasks(_tasks);
      final ids = _tasks.map((task) => task.id).toSet();
      _selectedTaskIds = Set.unmodifiable(
        resetSelection ? ids : _selectedTaskIds.intersection(ids),
      );
    } catch (_) {
      _tasks = const [];
      _selectedTaskIds = const {};
      _approvalError = 'Approve the current Plan to create a session. Saved sessions remain available.';
    }
  }

  void _refreshRunStatuses() {
    final selected = _selected;
    if (selected == null) {
      _runStatuses = const [];
      return;
    }
    try {
      _runStatuses = List.unmodifiable(_runStatusStore.load(selected));
    } catch (_) {
      _runStatuses = List.unmodifiable(
        selected.dispatches.map(AgentSessionRunStatus.unavailable),
      );
    }
  }

  /// Refresh only the still-selected history after child review; preserve choices.
  void refreshSelectedHistory(String sessionId) {
    final previous = _selected;
    if (_busy || isDisposed || previous?.sessionId != sessionId) return;
    bool current() => !isDisposed && !_busy && identical(_selected, previous);
    try {
      final value = store.load(sessionId);
      if (!current()) return;
      if (value == null) throw StateError('Selected session missing');
      final statuses = List<AgentSessionRunStatus>.unmodifiable(
        _runStatusStore.load(value),
      );
      if (!current()) return;
      _selected = value;
      _runStatuses = statuses;
      _error = null;
    } catch (_) {
      if (!current()) return;
      _runStatuses = List.unmodifiable(
        previous!.dispatches.map(AgentSessionRunStatus.unavailable),
      );
      _error = 'Selected session could not be refreshed. Its last visible snapshot is retained; new history is unavailable.';
    }
    update();
  }

  /// Select dependencies together; removing a prerequisite also removes dependents.
  void toggleTask(String id, bool selected) {
    if (_busy || isDisposed || !_tasks.any((task) => task.id == id)) return;
    final next = _selectedTaskIds.toSet();
    if (selected) {
      final byId = {for (final task in _tasks) task.id: task};
      void add(String taskId) {
        if (!next.add(taskId)) return;
        for (final dependency in byId[taskId]!.dependencies) {
          add(dependency);
        }
      }

      add(id);
    } else {
      next.remove(id);
      var changed = true;
      while (changed) {
        changed = false;
        for (final task in _tasks) {
          if (next.contains(task.id) &&
              task.dependencies.any((dep) => !next.contains(dep))) {
            next.remove(task.id);
            changed = true;
          }
        }
      }
    }
    _selectedTaskIds = Set.unmodifiable(next);
    update();
  }

  void open(String sessionId) {
    if (_busy || isDisposed) return;
    _error = null;
    try {
      final value = store.load(sessionId.trim());
      if (value == null) throw StateError('Not found');
      _selected = value;
      _refreshRunStatuses();
    } catch (_) {
      _error = 'Session could not be opened. Check the ID and saved records; existing data is retained.';
    }
    update();
  }

  /// Explicit navigation selection only; no records or execution are started.
  AgentSession? selectForSourceReview() {
    if (_busy || isDisposed || _selected == null) return null;
    try {
      final value = _selected!;
      AgentSessionRunAdmission(
        store.records,
        store.project,
        AgentSessionBinding.select(
          session: value,
          projectId: store.project.id,
          boardTaskId: value.tasks.items.first.id,
        ),
      ).requireCurrent();
      return value;
    } catch (_) {
      _error = 'This session cannot be used for source review. Reopen a current, uncancelled session for the approved Plan.';
      update();
      return null;
    }
  }

  Future<bool> _save(Future<AgentSession> Function() action) async {
    if (_busy || isDisposed) return false;
    _busy = true;
    _error = null;
    update();
    try {
      final value = await action();
      if (isDisposed) return false;
      _selected = value;
      _refresh();
      return true;
    } catch (_) {
      if (!isDisposed) {
        _error = 'Session update was not saved. Reload to review current approval and records, then retry. Existing data is retained.';
      }
      return false;
    } finally {
      _busy = false;
      update();
    }
  }

  Future<bool> create({required bool approved}) async {
    if (!approved || !canCreate) return false;
    final selection = _tasks
        .where((task) => _selectedTaskIds.contains(task.id))
        .map((task) => task.id)
        .toList();
    return _save(() => store.create(_createSessionId(), selection));
  }

  Future<bool> rememberSelected() async {
    final value = _selected;
    if (!canRemember || value == null) return false;
    return _save(() => store.remember(value.sessionId));
  }

  bool canOpenCandidate(int runNumber) {
    final value = _selected;
    if (_busy ||
        isDisposed ||
        value == null ||
        value.cancellationRequested ||
        value.dispatches.isEmpty ||
        value.dispatches.last.runNumber != runNumber) {
      return false;
    }
    try {
      CandidateReopenContextStore(
        store.records,
        store.project,
      ).loadLatest(value, runNumber);
      return true;
    } catch (_) {
      return false;
    }
  }

  SavedCandidateRecoveryController? createCandidateRecovery(int runNumber) {
    if (!canOpenCandidate(runNumber)) return null;
    return SavedCandidateRecoveryController(
      project: store.project,
      records: store.records,
      selectedSession: _selected!,
      runNumber: runNumber,
      createHost: createRecoveryHost,
    );
  }

  bool canReviewPublishedTask(int runNumber) {
    final value = _selected;
    if (_busy || isDisposed || value == null) return false;
    try {
      return _runStatusStore
              .load(value)
              .singleWhere((status) => status.reference.runNumber == runNumber)
              .publication !=
          null;
    } catch (_) {
      return false;
    }
  }

  PublishedTaskEvidenceController? createPublishedTaskEvidence(int runNumber) {
    if (!canReviewPublishedTask(runNumber)) return null;
    return PublishedTaskEvidenceController(
      PublishedTaskEvidenceStore(store.records, store.project),
      _selected!,
      runNumber,
    );
  }

  Future<bool> requestCancellation() async {
    final value = _selected;
    if (_busy || isDisposed || value == null || value.cancellationRequested) {
      return false;
    }
    return _save(() => store.requestCancellation(value));
  }
}
