// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/agent_execution_checkpoint.dart';
import '../models/agent_session.dart';
import '../models/build_plan.dart';
import '../models/candidate_verification_run.dart';
import '../models/project.dart';
import 'agent_execution_checkpoint_store.dart';
import 'candidate_verification_store.dart';
import 'plan_approval_store.dart';
import 'record_storage.dart';
import 'requirements_store.dart';

/// Stores observations, never invokes model, command, reconciliation or promotion.
final class AgentSessionStore {
  AgentSessionStore(this.records, this.project);
  final ConditionalRecordStorage records;
  final StudioProject project;

  String _key(String sessionId) {
    if (!AgentSessionTask.validId(sessionId) ||
        !AgentSessionTask.validId(project.id)) {
      throw const FormatException('Invalid agent session identity.');
    }
    return '${AgentSession.prefix}${project.id}.$sessionId';
  }

  /// Reopen is a read. Missing, revoked or old approvals do not erase history.
  AgentSession? load(String sessionId) {
    try {
      final key = _key(sessionId), raw = records.getString(key);
      if (raw == null) return null;
      if (utf8.encode(raw).length > AgentSession.maxEncodedBytes) {
        throw const FormatException('Agent session exceeds its storage bound.');
      }
      final value = AgentSession.fromJson(jsonDecode(raw));
      if (value.storageKey != key) throw const FormatException();
      return value;
    } catch (_) {
      throw const FormatException('Saved agent session is unreadable.');
    }
  }

  Map<String, String?> _approvalRecords() => {
    for (final key in [
      'studio.projects.v1',
      'studio.chat.v1.${project.id}',
      'studio.requirements.v1.${project.id}',
      'studio.application.v1.${project.id}',
      'studio.planApproval.v1.${project.id}',
    ])
      key: records.getString(key),
  };

  void _authorize(AgentSession value) {
    final approval = PlanApprovalStore(records).requireCurrentApproval(project);
    final board = RequirementsStore(records).load(project.id);
    final plan = BuildPlan.parse(approval.content, board: board);
    final selected = value.tasks.items.map((item) => item.id).toList();
    final current = AgentSessionTasks.fromBoardTasks([
      for (final id in selected)
        board.tasks.singleWhere((task) => task.id == id),
    ]);
    if (value.projectId != project.id ||
        !value.approval.matches(approval) ||
        jsonEncode(value.tasks.toJson()) != jsonEncode(current.toJson()) ||
        selected.any(
          (id) => !plan.tasks.any((task) => task.boardTaskId == id),
        )) {
      throw StateError('Session approval or task membership changed.');
    }
  }

  String _expected(AgentSession expected) {
    final key = _key(expected.sessionId), raw = records.getString(key);
    final saved = load(expected.sessionId);
    if (raw == null ||
        saved == null ||
        expected.projectId != project.id ||
        jsonEncode(saved.toJson()) != jsonEncode(expected.toJson())) {
      throw StateError('Agent session changed. Reopen it before updating.');
    }
    return raw;
  }

  Future<AgentSession> create(
    String sessionId,
    List<String> selectedTaskIds,
  ) async {
    if (selectedTaskIds.isEmpty ||
        selectedTaskIds.length > AgentSessionTasks.maxTasks ||
        selectedTaskIds.toSet().length != selectedTaskIds.length) {
      throw const FormatException('Duplicate session task selection.');
    }
    final board = RequirementsStore(records).load(project.id);
    final value = AgentSession.create(
      sessionId: sessionId,
      projectId: project.id,
      approval: PlanApprovalStore(records).requireCurrentApproval(project),
      tasks: AgentSessionTasks.fromBoardTasks([
        for (final id in selectedTaskIds)
          board.tasks.singleWhere((task) => task.id == id),
      ]),
    );
    _authorize(value);
    await records.commitRecords(
      expected: {_key(sessionId): null, ..._approvalRecords()},
      updates: {value.storageKey: jsonEncode(value.toJson())},
      authorize: () => _authorize(value),
    );
    return value;
  }

  /// Correlates an existing saved run with selected approved context. This does
  /// not prove a task completed, that a particular proposal ran, or any exit.
  Future<AgentSession> observeRun(
    AgentSession expected,
    String boardTaskId,
    CandidateVerificationRun run,
  ) async {
    final raw = _expected(expected);
    _authorize(expected);
    final journal = CandidateVerificationStore(records, project.id);
    final saved = journal
        .load()
        .runs
        .where((item) => item.number == run.number)
        .toList();
    final executionId = 'candidate-${project.id}-${run.number}';
    final checkpoint = AgentExecutionCheckpointStore(records).load(executionId);
    final plan = BuildPlan.parse(
      expected.approval.content,
      board: RequirementsStore(records).load(project.id),
    );
    if (saved.length != 1 ||
        jsonEncode(saved.single.toJson()) != jsonEncode(run.toJson()) ||
        run.dispatchId != '$executionId:3' ||
        checkpoint == null ||
        checkpoint.revision < 3 ||
        checkpoint.phase == AgentExecutionPhase.created ||
        checkpoint.phase == AgentExecutionPhase.planning ||
        run.snapshot.approval?.matches(expected.approval) != true ||
        !plan.matchesTasks(run.snapshot.tasks) ||
        !plan.tasks.any((task) => task.boardTaskId == boardTaskId)) {
      throw StateError(
        'Session dispatch evidence does not match saved approval.',
      );
    }
    final next = expected.observe(
      AgentSessionDispatch(
        boardTaskId: boardTaskId,
        runNumber: run.number,
        dispatchId: run.dispatchId!,
      ),
    );
    await records.commitRecords(
      expected: {
        expected.storageKey: raw,
        ..._approvalRecords(),
        journal.key: records.getString(journal.key),
        'studio.agentExecution.v1.$executionId': records.getString(
          'studio.agentExecution.v1.$executionId',
        ),
      },
      updates: {next.storageKey: jsonEncode(next.toJson())},
      authorize: () => _authorize(expected),
    );
    return next;
  }

  /// Cancellation is intent, so it can still be retained after approval revocation.
  /// It never alters the referenced dispatch or signals an external process.
  Future<AgentSession> requestCancellation(AgentSession expected) async {
    final raw = _expected(expected), next = expected.requestCancellation();
    await records.commitRecords(
      expected: {expected.storageKey: raw},
      updates: {next.storageKey: jsonEncode(next.toJson())},
      authorize: () {},
    );
    return next;
  }
}
