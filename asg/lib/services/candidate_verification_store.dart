// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/candidate_verification_run.dart';
import '../models/candidate_stop_request.dart';
import '../models/candidate_recovery_acknowledgement.dart';
import '../models/agent_execution_checkpoint.dart';
import '../models/source_generation.dart';
import 'record_storage.dart';
import 'agent_task_history_store.dart';
import '../models/agent_task_history.dart';
import 'agent_session_admission.dart';
import '../models/agent_session.dart';

/// Atomic journal and current checkpoint publication; stale writers fail closed.
class CandidateVerificationStore {
  CandidateVerificationStore(this.records, this.projectId);
  final RecordStorage records;
  final String projectId;
  String get key => 'studio.candidateChecks.v1.$projectId';
  String get candidateKey => 'studio.sourceCandidate.v1.$projectId';
  String? _expectedJournal, _expectedCandidate;
  CandidateVerificationRun? _owned, _session;
  AgentSession? _admittedSession;
  AgentTaskHistory? _taskHistory;
  String? _expectedTaskHistory;
  AgentSession? get admittedSession => _admittedSession;
  Future<void> _pending = Future<void>.value();
  static const recoveryPrefix = 'studio.candidateRecovery.v1.';

  CandidateRecoveryAcknowledgement? acknowledgementFor(
    CandidateVerificationRun run,
  ) {
    if (run.dispatchId == null) return null;
    final raw = records.getString('$recoveryPrefix${run.dispatchId}');
    if (raw == null) return null;
    try {
      final acknowledgement = CandidateRecoveryAcknowledgement.fromJson(
        jsonDecode(raw),
      );
      if (!acknowledgement.matches(projectId, run)) {
        throw const FormatException(
          'Recovery acknowledgement identity changed.',
        );
      }
      return acknowledgement;
    } on FormatException {
      throw const FormatException(
        'Saved recovery acknowledgement is unreadable.',
      );
    }
  }

  static const stopPrefix = 'studio.candidateStop.v1.';

  // Progress, Stop intent and terminal observations share one session write order.
  Future<T> _serial<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  CandidateStopRequest? stopRequestFor(CandidateVerificationRun run) {
    if (run.dispatchId == null) return null;
    final raw = records.getString('$stopPrefix${run.dispatchId}');
    if (raw == null) return null;
    try {
      final request = CandidateStopRequest.fromJson(jsonDecode(raw));
      if (!request.matches(projectId, run)) {
        throw const FormatException('Candidate Stop request identity changed.');
      }
      return request;
    } on FormatException {
      // Keep corrupt bytes in storage, not in FormatException.source.
      throw const FormatException(
        'Saved candidate Stop request is unreadable.',
      );
    }
  }

  Future<CandidateStopRequest?> requestStop(DateTime requestedAt) =>
      _serial(() async {
        final session = _session;
        if (session == null) {
          return null;
        } // Startup never committed, so no dispatch exists.
        final storage = records;
        if (storage is! ConditionalRecordStorage) {
          throw StateError('Atomic storage is required.');
        }
        final journalRaw = records.getString(key);
        final current = load().runs.last;
        final request = CandidateStopRequest.create(
          projectId,
          session,
          requestedAt,
        );
        if (journalRaw != _expectedJournal ||
            records.getString(candidateKey) != _expectedCandidate ||
            !request.matches(projectId, current)) {
          throw StateError('Candidate Stop request was superseded.');
        }
        final existing = stopRequestFor(current);
        if (existing != null) return existing;
        final executionKey =
            'studio.agentExecution.v1.${request.dispatchId.split(':').first}';
        final executionRaw = records.getString(executionKey);
        if (executionRaw == null) {
          throw StateError('Execution evidence is missing.');
        }
        final execution = AgentExecutionCheckpoint.fromJson(
          jsonDecode(executionRaw),
        );
        final dispatch = request.dispatchId.split(':');
        final matchesExecution =
            execution.taskId == dispatch.first &&
            (current.finished
                ? execution.phase == AgentExecutionPhase.verifying &&
                      execution.revision == int.parse(dispatch.last) + 1
                : execution.requiresReconciliation &&
                      execution.dispatchId == request.dispatchId);
        if (!matchesExecution) {
          throw StateError('Execution no longer matches the Stop request.');
        }
        await storage.commitRecords(
          expected: {
            key: journalRaw,
            candidateKey: _expectedCandidate,
            executionKey: executionRaw,
            '$stopPrefix${request.dispatchId}': null,
          },
          updates: {
            '$stopPrefix${request.dispatchId}': jsonEncode(request.toJson()),
          },
          authorize: () {},
        );
        return request;
      });

  CandidateVerificationJournal load() {
    final raw = records.getString(key);
    return raw == null
        ? CandidateVerificationJournal([])
        : CandidateVerificationJournal.fromJson(
            jsonDecode(raw) as Map<String, dynamic>,
          );
  }

  Future<CandidateVerificationRun> start(
    GeneratedProject snapshot,
    void Function() authorize, {
    String? dispatchId,
    AgentSessionRunAdmission? sessionAdmission,
  }) => _serial(
    () => _start(
      snapshot,
      authorize,
      dispatchId: dispatchId,
      sessionAdmission: sessionAdmission,
    ),
  );

  Future<CandidateVerificationRun> _start(
    GeneratedProject snapshot,
    void Function() authorize, {
    String? dispatchId,
    AgentSessionRunAdmission? sessionAdmission,
  }) async {
    if (_owned != null) throw StateError('Verification run already reserved.');
    _session = null;
    _admittedSession = null;
    _taskHistory = null;
    _expectedTaskHistory = null;
    if (sessionAdmission != null &&
        (!identical(sessionAdmission.records, records) ||
            sessionAdmission.project.id != projectId)) {
      throw StateError('Session admission belongs to another candidate store.');
    }
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
    final reservation = sessionAdmission?.prepare(run, execution);
    await _commit(
      [...journal.runs, run],
      snapshot,
      authorize,
      execution: execution,
      reservation: reservation,
    );
    _admittedSession = reservation?.next;
    _owned = run;
    _session = run;
    return run;
  }

  Future<void> checkpoint(
    GeneratedProject snapshot,
    void Function() authorize, {
    bool finished = false,
  }) => _serial(() => _checkpoint(snapshot, authorize, finished: finished));

  Future<void> _checkpoint(
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

  Future<void> acknowledgeStopped(
    CandidateVerificationRun expected,
    void Function() authorize,
  ) async {
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw StateError('Atomic storage is required.');
    }
    final raw = records.getString(key);
    final journal = load();
    if (journal.runs.isEmpty ||
        jsonEncode(journal.runs.last.toJson()) !=
            jsonEncode(expected.toJson()) ||
        expected.finished ||
        expected.snapshot.pendingOperation.isEmpty) {
      throw StateError('Interrupted verification changed.');
    }
    final stopped = CandidateVerificationRun(
      number: expected.number,
      startedAt: expected.startedAt,
      snapshot: expected.snapshot.copy(phase: SourceGenerationPhase.failed),
      finished: true,
      dispatchId: expected.dispatchId,
    );
    final updated = CandidateVerificationJournal([
      ...journal.runs.take(journal.runs.length - 1),
      stopped,
    ]);
    String? executionKey, executionRaw, reconciled;
    if (expected.dispatchId != null) {
      executionKey =
          'studio.agentExecution.v1.${expected.dispatchId!.split(':').first}';
      executionRaw = records.getString(executionKey);
      if (executionRaw == null) {
        throw StateError('Interrupted execution evidence is missing.');
      }
      var saved = AgentExecutionCheckpoint.fromJson(jsonDecode(executionRaw));
      if (saved.dispatchId != expected.dispatchId) {
        throw StateError('Interrupted execution changed.');
      }
      if (saved.phase == AgentExecutionPhase.executing) {
        saved = saved.advance(AgentExecutionPhase.recovering);
      }
      reconciled = jsonEncode(
        saved.advance(AgentExecutionPhase.awaitingApproval).toJson(),
      );
    }
    final acknowledgement = expected.dispatchId == null
        ? null
        : CandidateRecoveryAcknowledgement.create(
            projectId,
            expected,
            stopped,
            DateTime.now().toUtc(),
          );
    final acknowledgementKey = acknowledgement == null
        ? null
        : '$recoveryPrefix${acknowledgement.dispatchId}';
    final acknowledgementRaw = acknowledgement == null
        ? null
        : jsonEncode(acknowledgement.toJson());
    await storage.commitRecords(
      expected: {
        key: raw,
        if (reconciled != null) executionKey!: executionRaw,
        ?acknowledgementKey: null,
      },
      updates: {
        key: jsonEncode(updated.toJson()),
        ?executionKey: ?reconciled,
        ?acknowledgementKey: ?acknowledgementRaw,
      },
      authorize: authorize,
    );
  }

  Future<void> _commit(
    List<CandidateVerificationRun> runs,
    GeneratedProject snapshot,
    void Function() authorize, {
    AgentExecutionCheckpoint? execution,
    AgentSessionReservation? reservation,
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
    String? historyKey, historyRaw, sessionRaw, historySessionKey;
    AgentTaskHistory? nextHistory;
    if (reservation != null) {
      nextHistory = AgentTaskHistoryStore.start(reservation.next, runs.last);
    } else if (_taskHistory != null) {
      final saved = records.getString(_taskHistory!.session.storageKey);
      if (saved == null) throw StateError('Admitted task session is missing.');
      sessionRaw = saved;
      historySessionKey = _taskHistory!.session.storageKey;
      final current = AgentSession.fromJson(jsonDecode(saved));
      nextHistory = AgentTaskHistoryStore.advance(
        _taskHistory!,
        _owned!,
        runs.last,
        current,
      );
    }
    if (nextHistory != null) {
      historyKey = AgentTaskHistoryStore(
        records,
        projectId,
      ).keyFor(runs.last.number);
      historyRaw = jsonEncode(nextHistory.toJson());
    }
    await storage.commitRecords(
      expected: {
        ?historyKey: _expectedTaskHistory,
        ?historySessionKey: sessionRaw,
        if (reservation != null) ...{
          ...reservation.expectedContext,
          reservation.sessionKey: reservation.expectedSession,
        },
        key: _expectedJournal,
        candidateKey: _expectedCandidate,
        if (updatedExecution != null) executionKey!: expectedExecution,
      },
      updates: {
        ?historyKey: historyRaw!,
        if (reservation != null)
          reservation.sessionKey: reservation.updatedSession,
        key: raw,
        candidateKey: candidate,
        ?executionKey: ?updatedExecution,
      },
      authorize: () {
        authorize();
        reservation?.requireCurrent();
      },
    );
    _expectedJournal = raw;
    _expectedCandidate = candidate;
    _taskHistory = nextHistory;
    _expectedTaskHistory = historyRaw;
  }
}
