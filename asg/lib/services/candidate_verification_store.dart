// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/candidate_verification_run.dart';
import '../models/agent_execution_checkpoint.dart';
import '../models/source_generation.dart';
import 'record_storage.dart';

/// Atomic journal and current checkpoint publication; stale writers fail closed.
class CandidateVerificationStore {
  CandidateVerificationStore(this.records, this.projectId);
  final RecordStorage records;
  final String projectId;
  String get key => 'studio.candidateChecks.v1.$projectId';
  String get candidateKey => 'studio.sourceCandidate.v1.$projectId';
  String? _expectedJournal, _expectedCandidate;
  CandidateVerificationRun? _owned;

  CandidateVerificationJournal load() {
    final raw = records.getString(key);
    return raw == null
        ? CandidateVerificationJournal([])
        : CandidateVerificationJournal.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
  }

  Future<void> start(
    GeneratedProject snapshot,
    void Function() authorize, {
    String? dispatchId,
  }) async {
    if (_owned != null) throw StateError('Verification run already reserved.');
    _expectedJournal = records.getString(key);
    _expectedCandidate = records.getString(candidateKey);
    final journal = load();
    if (journal.runs.isNotEmpty &&
        !journal.runs.last.finished &&
        journal.runs.last.snapshot.pendingOperation.isNotEmpty) {
      throw StateError('Reconcile the interrupted candidate operation first.');
    }
    final execution = dispatchId == null
        ? AgentExecutionCheckpoint.create(
                'candidate-$projectId-${journal.runs.length + 1}',
              )
              .advance(AgentExecutionPhase.planning)
              .advance(AgentExecutionPhase.awaitingApproval)
              .advance(AgentExecutionPhase.executing)
        : null;
    final run = CandidateVerificationRun(
      number: journal.runs.length + 1,
      startedAt: DateTime.now().toUtc(),
      snapshot: snapshot,
      finished: false,
      dispatchId: dispatchId ?? execution?.dispatchId,
    );
    await _commit(
      [...journal.runs, run],
      snapshot,
      authorize,
      execution: execution,
    );
    _owned = run;
  }

  Future<void> checkpoint(
    GeneratedProject snapshot,
    void Function() authorize, {
    bool finished = false,
  }) async {
    final owned = _owned;
    if (owned == null) throw StateError('No reserved verification run.');
    final run = CandidateVerificationRun(
      number: owned.number,
      startedAt: owned.startedAt,
      snapshot: snapshot,
      finished: finished,
      dispatchId: owned.dispatchId,
    );
    final journal = load();
    await _commit(
      [...journal.runs.take(owned.number - 1), run],
      snapshot,
      authorize,
    );
    _owned = finished ? null : run;
  }

  Future<void> _commit(
    List<CandidateVerificationRun> runs,
    GeneratedProject snapshot,
    void Function() authorize, {
    AgentExecutionCheckpoint? execution,
  }) async {
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw StateError('Atomic storage is required for candidate checks.');
    }
    final raw = jsonEncode(CandidateVerificationJournal(runs).toJson());
    CandidateVerificationJournal.fromJson(
      jsonDecode(raw) as Map<String, dynamic>,
    );
    final candidate = jsonEncode(snapshot.toJson());
    String? executionKey, expectedExecution, updatedExecution;
    if (execution != null) {
      executionKey = 'studio.agentExecution.v1.${execution.taskId}';
      updatedExecution = jsonEncode(execution.toJson());
    } else if (runs.last.finished && runs.last.dispatchId != null) {
      final id = runs.last.dispatchId!;
      executionKey = 'studio.agentExecution.v1.${id.split(':').first}';
      expectedExecution = records.getString(executionKey);
      if (expectedExecution != null) {
        final saved = AgentExecutionCheckpoint.fromJson(
          jsonDecode(expectedExecution),
        );
        if (saved.dispatchId != id ||
            saved.phase != AgentExecutionPhase.executing) {
          throw StateError('Verification execution changed.');
        }
        updatedExecution = jsonEncode(
          saved.advance(AgentExecutionPhase.verifying).toJson(),
        );
      }
    }
    await storage.commitRecords(
      expected: {
        key: _expectedJournal,
        candidateKey: _expectedCandidate,
        if (updatedExecution != null) executionKey!: expectedExecution,
      },
      updates: {
        key: raw,
        candidateKey: candidate,
        ?executionKey: ?updatedExecution,
      },
      authorize: authorize,
    );
    _expectedJournal = raw;
    _expectedCandidate = candidate;
  }
}
