// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/agent_session.dart';
import '../models/agent_session_run_status.dart';
import '../models/build_task.dart';
import '../models/structured_proposal_json.dart';
import '../models/candidate_verification_run.dart';
import 'agent_execution_checkpoint_store.dart';
import 'record_storage.dart';

/// Reads retained history only. Does not reopen/reconcile checkpoints or require
/// current execution approval, so revoked and cancelled history stays readable.
class AgentSessionRunStatusStore {
  AgentSessionRunStatusStore(this.records, this.projectId);
  final ConditionalRecordStorage records;
  final String projectId;

  List<AgentSessionRunStatus> load(AgentSession session) {
    CandidateVerificationJournal? journal;
    try {
      final raw = records.getString(session.storageKey);
      if (session.projectId != projectId ||
          raw == null ||
          utf8.encode(raw).length > AgentSession.maxEncodedBytes ||
          jsonEncode(AgentSession.fromJson(jsonDecode(raw)).toJson()) !=
              jsonEncode(session.toJson())) {
        throw const FormatException();
      }
      final saved = records.getString('studio.candidateChecks.v1.$projectId');
      if (saved != null) {
        journal = CandidateVerificationJournal.fromJson(
          jsonDecode(saved) as Map<String, dynamic>,
        );
      }
    } catch (_) {
      // Never expose malformed bytes or replace the retained records.
    }
    return List.unmodifiable([
      for (final reference in session.dispatches)
        _read(session, reference, journal),
    ]);
  }

  // Compare the retained wire graph without consulting today's board or
  // reauthorizing it. The complete historical board is not stored in a run.
  bool _matchesApprovedGraph(
    AgentSession session,
    CandidateVerificationRun run,
  ) {
    final content = session.approval.content;
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
    if (value is! Map ||
        value.length != 3 ||
        value['version'] is! int ||
        ![3, 4].contains(value['version']) ||
        value['adapter'] != 'flutter-starter')
      return false;
    final tasks = BuildTask.fromJson(value['tasks']);
    return jsonEncode(tasks.map((task) => task.toJson()).toList()) ==
        jsonEncode(run.snapshot.tasks?.map((task) => task.toJson()).toList());
  }

  AgentSessionRunStatus _read(
    AgentSession session,
    AgentSessionDispatch reference,
    CandidateVerificationJournal? journal,
  ) {
    try {
      final run = journal?.runs
          .where((run) => run.number == reference.runNumber)
          .single;
      final executionId = 'candidate-$projectId-${reference.runNumber}';
      final execution = AgentExecutionCheckpointStore(records)
          .load(executionId);
      final tasks = run?.snapshot.tasks;
      if (run == null ||
          tasks == null ||
          execution == null ||
          execution.revision < 3 ||
          (!execution.requiresReconciliation && execution.revision < 4) ||
          reference.dispatchId != '$executionId:3' ||
          run.dispatchId != reference.dispatchId ||
          run.snapshot.approval?.matches(session.approval) != true ||
          !_matchesApprovedGraph(session, run) ||
          !session.tasks.items.any(
            (task) => task.id == reference.boardTaskId,
          ) ||
          !tasks.any((task) => task.boardTaskId == reference.boardTaskId) ||
          session.tasks.items.any(
            (selected) => !tasks.any((task) => task.boardTaskId == selected.id),
          ) ||
          (execution.requiresReconciliation &&
              execution.dispatchId != reference.dispatchId)) {
        throw const FormatException();
      }
      return AgentSessionRunStatus.recorded(
        reference: reference,
        sourcePhase: run.snapshot.phase,
        executionPhase: execution.phase,
        pendingOperation: run.snapshot.pendingOperation,
        finished: run.finished,
      );
    } catch (_) {
      return AgentSessionRunStatus.unavailable(reference);
    }
  }
}
