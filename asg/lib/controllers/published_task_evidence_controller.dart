// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/agent_session.dart';
import '../models/agent_task_decision.dart';
import '../models/published_task_evidence.dart';
import '../services/agent_task_decision_store.dart';
import '../services/published_task_evidence_store.dart';
import 'base_controller.dart';

/// Reads saved facts; only explicit confirmation can publish one decision record.
class PublishedTaskEvidenceController extends BaseController {
  PublishedTaskEvidenceController(
    this.store,
    this.selectedSession,
    this.runNumber, {
    AgentTaskDecisionStore? decisions,
  }) : decisions =
           decisions ?? AgentTaskDecisionStore(store.records, store.project);
  final PublishedTaskEvidenceStore store;
  final AgentSession selectedSession;
  final int runNumber;
  final AgentTaskDecisionStore decisions;
  PublishedTaskEvidence? _evidence;
  String? _error, _decisionError;
  AgentTaskDecision? _decision;
  AgentTaskDecisionSelection? _selection;
  final Map<String, int> _prerequisites = {};
  Map<String, List<int>> _options = {};
  bool _consent = false, _busy = false;
  int _epoch = 0;
  PublishedTaskEvidence? get evidence => _evidence;
  String? get error => _error;
  String? get decisionError => _decisionError;
  AgentTaskDecision? get decision => _decision;
  bool get consent => _consent;
  bool get busy => _busy;
  bool get canConsent =>
      !isDisposed && !_busy && _selection != null && _decision == null;
  bool get canConfirm => canConsent && _consent;
  Map<String, List<int>> get prerequisiteOptions => Map.unmodifiable(_options);
  int? prerequisiteSelection(String id) => _prerequisites[id];

  void load() {
    if (isDisposed || _busy) return;
    _epoch++;
    _evidence = null;
    _error = null;
    _decision = null;
    _decisionError = null;
    _selection = null;
    _consent = false;
    _prerequisites.clear();
    _options = {};
    try {
      _decision = decisions.load(selectedSession, runNumber);
    } catch (_) {
      _decisionError = 'Retained decision proof is unavailable. Existing records are preserved.';
    }
    try {
      final value = store.load(selectedSession, runNumber);
      if (!isDisposed) _evidence = value;
    } catch (_) {
      if (!isDisposed) _error = 'Published task evidence is unavailable for this saved selection. Check its publication, working output, session, Plan and saved inputs. Existing history is retained; another run is not selected automatically.';
    }
    if (isDisposed) return;
    if (_evidence != null &&
        _decision == null &&
        !selectedSession.cancellationRequested) {
      try {
        final task = selectedSession.tasks.items.singleWhere(
          (t) => t.id == _evidence!.taskId,
        );
        _options = {
          for (final id in task.dependencies)
            id: List.unmodifiable([
              for (final ref in selectedSession.dispatches)
                if (ref.boardTaskId == id &&
                    ref.runNumber < runNumber &&
                    _hasDecision(ref.runNumber))
                  ref.runNumber,
            ]),
        };
        _select();
      } catch (_) {
        _decisionError = 'Completion decision is unavailable. Reload exact saved evidence and prerequisite decisions.';
      }
    }
    update();
  }

  bool _hasDecision(int number) {
    try {
      return decisions.load(selectedSession, number) != null;
    } catch (_) {
      return false;
    }
  }

  void _select() {
    _selection = null;
    _consent = false;
    try {
      _selection = decisions.select(
        selectedSession,
        runNumber,
        prerequisites: _prerequisites,
      );
      _decisionError = null;
    } catch (_) {
      _decisionError = 'Completion decision requires every nonempty authored named-test rule to pass and an explicit retained decision for each prerequisite. Manual, advisory, unmapped, stale or missing evidence cannot complete this contract.';
    }
  }

  void choosePrerequisite(String id, int? number) {
    if (isDisposed ||
        _busy ||
        !_options.containsKey(id) ||
        (number != null && !_options[id]!.contains(number))) {
      return;
    }
    _epoch++;
    if (number == null) {
      _prerequisites.remove(id);
    } else {
      _prerequisites[id] = number;
    }
    _select();
    update();
  }

  void setConsent(bool value) {
    if (!canConsent) return;
    _consent = value;
    update();
  }

  void cancelConfirmation() {
    if (isDisposed || !_busy) return;
    _epoch++;
    _consent = false;
    _selection = null;
    _decisionError = 'Confirmation was withdrawn. Reload saved history to inspect any decision already committed.';
    update();
  }

  Future<bool> confirm() async {
    if (!canConfirm) return false;
    final selection = _selection!;
    final epoch = _epoch;
    _busy = true;
    update();
    try {
      final value = await decisions.confirm(
        selection,
        consent: true,
        authorized: () => !isDisposed && epoch == _epoch && _consent,
      );
      if (isDisposed || epoch != _epoch) return false;
      _decision = value;
      _selection = null;
      _consent = false;
      _decisionError = null;
      return true;
    } catch (_) {
      if (!isDisposed && epoch == _epoch) {
        _selection = null;
        _consent = false;
        _decisionError = 'Decision was not confirmed. Evidence, consent or storage changed. Reload saved history before trying again; existing records are retained.';
      }
      return false;
    } finally {
      if (!isDisposed) {
        _busy = false;
        update();
      }
    }
  }
}
