// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/agent_session.dart';
import '../models/agent_task_history.dart';
import '../models/build_task.dart';
import '../models/candidate_verification_run.dart';
import '../models/source_generation.dart';
import '../models/structured_proposal_json.dart';
import 'record_storage.dart';

/// Read-only history access and pure transaction inputs. Only the candidate
/// store publishes these values, jointly with its journal and checkpoints.
class AgentTaskHistoryStore {
  AgentTaskHistoryStore(this.records, this.projectId);
  final RecordStorage records;
  final String projectId;
  static const prefix = 'studio.agentTaskHistory.v1.';
  String keyFor(int runNumber) => '$prefix$projectId.$runNumber';

  static AgentTaskHistory decode(String key, String raw) {
    if (utf8.encode(raw).length > AgentTaskHistory.maxEncodedBytes) {
      throw const FormatException('Task history exceeds its bound.');
    }
    try {
      final value = jsonDecode(raw);
      final basis = AgentSession.fromJson(value['session']);
      final current = value['withdrawalSequence'] == null
          ? basis
          : basis.requestCancellation();
      final history = AgentTaskHistory.fromJson(value, currentSession: current);
      if (key != '$prefix${basis.projectId}.${history.reference.runNumber}') {
        throw const FormatException();
      }
      return history;
    } catch (_) {
      throw const FormatException('Saved task history is unreadable.');
    }
  }

  AgentTaskHistory? load(CandidateVerificationRun run) {
    try {
      return _load(run);
    } catch (_) {
      throw const FormatException('Saved task history is unavailable.');
    }
  }

  AgentTaskHistory? _load(CandidateVerificationRun run) {
    final raw = records.getString(keyFor(run.number));
    if (raw == null) return null; // Legacy/unbound runs are never backfilled.
    final history = decode(keyFor(run.number), raw);
    requireRun(history, run);
    final saved = records.getString(history.session.storageKey);
    if (saved == null) {
      throw const FormatException('Task session is unavailable.');
    }
    final current = AgentSession.fromJson(jsonDecode(saved));
    final basis = history.session;
    if (current.projectId != basis.projectId ||
        current.sessionId != basis.sessionId ||
        !current.approval.matches(basis.approval) ||
        jsonEncode(current.tasks.toJson()) !=
            jsonEncode(basis.tasks.toJson()) ||
        current.dispatches.length < basis.dispatches.length ||
        jsonEncode(
              current.dispatches
                  .take(basis.dispatches.length)
                  .map((item) => item.toJson())
                  .toList(),
            ) !=
            jsonEncode(
              basis.dispatches.map((item) => item.toJson()).toList(),
            ) ||
        (history.withdrawalSequence != null &&
            !current.cancellationRequested)) {
      throw const FormatException('Task history session changed.');
    }
    return history;
  }

  static void requireRun(
    AgentTaskHistory history,
    CandidateVerificationRun run,
  ) {
    final snapshot = run.snapshot, tasks = run.snapshot.tasks;
    if (history.reference.runNumber != run.number ||
        history.reference.dispatchId != run.dispatchId ||
        snapshot.approval?.matches(history.session.approval) != true ||
        tasks == null ||
        !tasks.any(
          (item) => item.boardTaskId == history.reference.boardTaskId,
        ) ||
        history.session.tasks.items.any(
          (item) => !tasks.any((task) => task.boardTaskId == item.id),
        ) ||
        jsonEncode(tasks.map((item) => item.operation.name).toList()) !=
            jsonEncode(
              history.operationOrder.map((item) => item.name).toList(),
            ) ||
        !_matchesApprovedGraph(history.session.approval.content, tasks) ||
        snapshot.steps.length != history.results.length ||
        history.pendingOperation?.name !=
            (snapshot.pendingOperation.isEmpty
                ? null
                : snapshot.pendingOperation) ||
        history.finished !=
            (run.finished && snapshot.pendingOperation.isEmpty)) {
      throw const FormatException('Task history does not match the saved run.');
    }
    for (var index = 0; index < snapshot.steps.length; index++) {
      final step = snapshot.steps[index], result = history.results[index];
      if (step.operation != result.operation?.name ||
          step.exitCode != result.exitCode ||
          step.cancelled != result.cancelled) {
        throw const FormatException('Task result differs from the saved run.');
      }
    }
  }

  // Correlation with the frozen wire graph, not current board authorization.
  static bool _matchesApprovedGraph(String content, List<BuildTask> tasks) {
    final markers = RegExp(
      r'^```asg-build[^\r\n]*',
      multiLine: true,
    ).allMatches(content);
    final blocks = RegExp(
      r'^```asg-build\r?\n([\s\S]*?)^```[ \t]*\r?$',
      multiLine: true,
    ).allMatches(content);
    if (markers.length != 1 || blocks.length != 1) return false;
    final raw = blocks.single.group(1)!;
    rejectDuplicateJsonMembers(raw);
    final value = jsonDecode(raw);
    return value is Map &&
        value.length == 3 &&
        value['version'] is int &&
        [3, 4].contains(value['version']) &&
        value['adapter'] == 'flutter-starter' &&
        jsonEncode(
              BuildTask.fromJson(value['tasks'])
                  .map((item) => item.toJson())
                  .toList(),
            ) ==
            jsonEncode(tasks.map((item) => item.toJson()).toList());
  }

  static AgentTaskHistory start(
    AgentSession session,
    CandidateVerificationRun run,
  ) {
    if (run.snapshot.steps.isNotEmpty ||
        run.finished ||
        run.snapshot.phase != SourceGenerationPhase.verifying) {
      throw const FormatException('Task admission needs a fresh verification.');
    }
    var history = AgentTaskHistory.start(
      session: session,
      reference: session.dispatches.last,
      operationOrder: run.snapshot.tasks!
          .map((item) => item.operation)
          .toList(),
    );
    if (run.snapshot.pendingOperation.isNotEmpty) {
      history = _append(
        history,
        session,
        'pending',
        run.snapshot.pendingOperation,
      );
    }
    requireRun(history, run);
    return history;
  }

  static AgentTaskHistory advance(
    AgentTaskHistory history,
    CandidateVerificationRun previous,
    CandidateVerificationRun next,
    AgentSession current,
  ) {
    requireRun(history, previous);
    if (previous.number != next.number ||
        previous.dispatchId != next.dispatchId ||
        previous.startedAt != next.startedAt ||
        previous.finished ||
        jsonEncode(_stable(previous.snapshot)) !=
            jsonEncode(_stable(next.snapshot)) ||
        next.snapshot.steps.length < previous.snapshot.steps.length ||
        next.snapshot.steps.length > previous.snapshot.steps.length + 1 ||
        jsonEncode(
              next.snapshot.steps
                  .take(previous.snapshot.steps.length)
                  .map((item) => item.toJson())
                  .toList(),
            ) !=
            jsonEncode(
              previous.snapshot.steps.map((item) => item.toJson()).toList(),
            )) {
      throw const FormatException(
        'Task checkpoint changed immutable evidence.',
      );
    }
    var updated = AgentTaskHistory.fromJson(
      history.toJson(),
      currentSession: current,
    );
    if (current.cancellationRequested) {
      updated = updated.observeWithdrawal(currentSession: current);
    }
    final snapshot = next.snapshot;
    final addedResult = snapshot.steps.length > previous.snapshot.steps.length;
    if (addedResult) {
      if (snapshot.pendingOperation.isNotEmpty) {
        throw const FormatException(
          'Result and dispatch must be separate checkpoints.',
        );
      }
      final step = snapshot.steps.last;
      updated = _append(
        updated,
        current,
        'result',
        step.operation,
        step.exitCode,
        step.cancelled,
      );
    }
    if (snapshot.pendingOperation.isNotEmpty &&
        updated.pendingOperation == null) {
      if (snapshot.phase == SourceGenerationPhase.failed ||
          snapshot.steps.any((step) => !step.succeeded)) {
        throw const FormatException(
          'Failed observation cannot dispatch an operation.',
        );
      }
      updated = _append(updated, current, 'pending', snapshot.pendingOperation);
    }
    if (snapshot.pendingOperation.isNotEmpty &&
        snapshot.phase == SourceGenerationPhase.failed &&
        updated.observations.last.kind !=
            AgentTaskObservationKind.interrupted) {
      updated = _append(
        updated,
        current,
        'interrupted',
        snapshot.pendingOperation,
      );
    }
    if (next.finished) updated = _append(updated, current, 'finished');
    requireRun(updated, next);
    return updated;
  }

  static Map<String, Object> _stable(GeneratedProject snapshot) =>
      snapshot.toJson()..removeWhere(
        (key, _) => const {
          'outputs',
          'resolution',
          'steps',
          'phase',
          'error',
          'failedOperation',
          'pendingOperation',
        }.contains(key),
      );

  static AgentTaskHistory _append(
    AgentTaskHistory history,
    AgentSession current,
    String kind, [
    String? operation,
    int? exitCode,
    bool? cancelled,
  ]) => history.append(
    AgentTaskObservation.fromJson({
      'sequence': history.observations.length,
      'kind': kind,
      'operation': operation,
      'exitCode': exitCode,
      'cancelled': cancelled,
    }),
    currentSession: current,
  );
}
