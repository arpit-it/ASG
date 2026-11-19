// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/agent_session.dart';
import '../models/agent_task_decision.dart';
import '../models/published_task_evidence.dart';
import '../models/prerequisite_preparation_evidence.dart';
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
    AgentPrerequisitePreparationStore? preparation,
  }) : decisions =
           decisions ?? AgentTaskDecisionStore(store.records, store.project),
       preparation =
           preparation ??
           AgentPrerequisitePreparationStore(store.records, store.project.id);
  final PublishedTaskEvidenceStore store;
  final AgentSession selectedSession;
  final int runNumber;
  final AgentTaskDecisionStore decisions;
  final AgentPrerequisitePreparationStore preparation;
  PrerequisitePreparationReview? _preparationReview;
  String? _preparationError;
  PrerequisitePreparationReview? get preparationReview => _preparationReview;
  String? get preparationError => _preparationError;
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
    final epoch = ++_epoch;
    _preparationReview = null;
    _preparationError = null;
    _evidence = null;
    _error = null;
    _decision = null;
    _decisionError = null;
    _selection = null;
    _consent = false;
    _prerequisites.clear();
    _options = {};
    try {
      final value = decisions.load(selectedSession, runNumber);
      if (!isDisposed && epoch == _epoch) _decision = value;
    } catch (_) {
      if (!isDisposed && epoch == _epoch) _decisionError = 'Retained decision proof is unavailable. Existing records are preserved.';
    }
    if (isDisposed || epoch != _epoch) return;
    try {
      final value = store.load(selectedSession, runNumber);
      if (!isDisposed && epoch == _epoch) _evidence = value;
    } catch (_) {
      if (!isDisposed && epoch == _epoch) _error = 'Published task evidence is unavailable for this saved selection. Check its publication, working output, session, Plan and saved inputs. Existing history is retained; another run is not selected automatically.';
    }
    if (isDisposed || epoch != _epoch) return;
    if (_evidence != null &&
        _decision == null &&
        !selectedSession.cancellationRequested) {
      try {
        final task = selectedSession.tasks.items.singleWhere(
          (t) => t.id == _evidence!.taskId,
        );
        final options = <String, List<int>>{
          for (final id in task.dependencies)
            id: List.unmodifiable([
              for (final ref in selectedSession.dispatches)
                if (ref.boardTaskId == id &&
                    ref.runNumber < runNumber &&
                    _hasDecision(ref.runNumber))
                  ref.runNumber,
            ]),
        };
        if (isDisposed || epoch != _epoch) return;
        _options = options;
        _select();
      } catch (_) {
        if (!isDisposed && epoch == _epoch) _decisionError = 'Completion decision is unavailable. Reload exact saved evidence and prerequisite decisions.';
      }
    }
    if (_decision case final retained?) _loadPreparation(retained, epoch);
    if (isDisposed || epoch != _epoch) return;
    update();
  }

  void _loadPreparation(AgentTaskDecision decision, int epoch) {
    if (isDisposed || epoch != _epoch) return;
    _preparationReview = null;
    _preparationError = null;
    try {
      final value = preparation.load(selectedSession, runNumber);
      if (isDisposed || epoch != _epoch) return;
      if (value == null ||
          value.decisionSha256 != decision.fingerprint ||
          value.runNumber != runNumber) {
        throw StateError('Retained decision changed.');
      }
      _preparationReview = value;
    } catch (_) {
      if (!isDisposed && epoch == _epoch) {
        _preparationError = 'Recorded preparation provenance is unavailable. The retained authored-check decision remains separate; reload saved evidence to retry.';
      }
    }
  }

  bool _hasDecision(int number) {
    if (isDisposed) return false;
    try {
      final value = decisions.load(selectedSession, number);
      return !isDisposed && value != null;
    } catch (_) {
      return false;
    }
  }

  void _select() {
    _selection = null;
    _consent = false;
    try {
      final selection = decisions.select(
        selectedSession,
        runNumber,
        prerequisites: _prerequisites,
      );
      if (!isDisposed) {
        _selection = selection;
        _decisionError = null;
      }
    } catch (_) {
      if (!isDisposed) _decisionError = 'Completion decision requires every nonempty authored named-test rule to pass and an explicit retained decision for each prerequisite. Manual, advisory, unmapped, stale or missing evidence cannot complete this contract.';
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
      _loadPreparation(value, epoch);
      return !isDisposed && epoch == _epoch;
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
