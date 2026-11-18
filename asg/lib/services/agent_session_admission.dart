// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/agent_session.dart';
import '../models/agent_session_binding.dart';
import '../models/agent_execution_checkpoint.dart';
import '../models/candidate_verification_run.dart';
import '../models/build_plan.dart';
import '../models/project.dart';
import 'plan_approval_store.dart';
import 'record_storage.dart';
import 'requirements_store.dart';

/// Shared current-approval checks. Validation alone grants no execution authority.
final class AgentSessionAdmission {
  AgentSessionAdmission(this.records, this.project);
  final RecordStorage records;
  final StudioProject project;

  Map<String, String?> approvalRecords() => {
    for (final key in [
      'studio.projects.v1',
      'studio.chat.v1.${project.id}',
      'studio.requirements.v1.${project.id}',
      'studio.application.v1.${project.id}',
      'studio.planApproval.v1.${project.id}',
    ])
      key: records.getString(key),
  };

  void requireApproval(AgentSession value) {
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
}

/// A typed request to append one session reference in candidate startup's CAS.
/// It cannot commit independently or supply arbitrary transaction updates.
final class AgentSessionRunAdmission {
  AgentSessionRunAdmission(this.records, this.project, this.binding);
  final RecordStorage records;
  final StudioProject project;
  final AgentSessionBinding binding;

  String requireCurrent() {
    final session = binding.session;
    final raw = records.getString(session.storageKey);
    if (raw == null || utf8.encode(raw).length > AgentSession.maxEncodedBytes) {
      throw StateError('Selected session is missing or unreadable.');
    }
    final saved = AgentSession.fromJson(jsonDecode(raw));
    if (saved.storageKey != session.storageKey ||
        saved.cancellationRequested ||
        jsonEncode(saved.toJson()) != jsonEncode(session.toJson())) {
      throw StateError(
        'Selected session changed. Reopen it before verification.',
      );
    }
    AgentSessionBinding.select(
      session: saved,
      projectId: project.id,
      boardTaskId: binding.boardTaskId,
    );
    AgentSessionAdmission(records, project).requireApproval(saved);
    return raw;
  }

  AgentSessionReservation prepare(
    CandidateVerificationRun run,
    AgentExecutionCheckpoint? execution,
  ) {
    final raw = requireCurrent();
    final plan = BuildPlan.parse(
      binding.session.approval.content,
      board: RequirementsStore(records).load(project.id),
    );
    final executionId = 'candidate-${project.id}-${run.number}';
    if (execution == null ||
        execution.taskId != executionId ||
        execution.phase != AgentExecutionPhase.executing ||
        execution.revision != 3 ||
        run.finished ||
        run.dispatchId != '$executionId:3' ||
        run.snapshot.approval?.matches(binding.session.approval) != true ||
        !plan.matchesTasks(run.snapshot.tasks)) {
      throw StateError('Session admission does not match candidate startup.');
    }
    final next = binding.session.observe(
      AgentSessionDispatch(
        boardTaskId: binding.boardTaskId,
        runNumber: run.number,
        dispatchId: run.dispatchId!,
      ),
    );
    binding.admitted(next, run.dispatchId!);
    return AgentSessionReservation._(
      this,
      raw,
      next,
      AgentSessionAdmission(records, project).approvalRecords(),
    );
  }
}

/// Validated fixed-key input, consumed only by the candidate startup transaction.
final class AgentSessionReservation {
  AgentSessionReservation._(
    this.request,
    this.expectedSession,
    this.next,
    Map<String, String?> context,
  ) : expectedContext = Map.unmodifiable(context);
  final AgentSessionRunAdmission request;
  final String expectedSession;
  final AgentSession next;
  final Map<String, String?> expectedContext;
  String get sessionKey => next.storageKey;
  String get updatedSession => jsonEncode(next.toJson());

  void requireCurrent() {
    if (request.requireCurrent() != expectedSession ||
        expectedContext.entries.any(
          (entry) => request.records.getString(entry.key) != entry.value,
        )) {
      throw StateError('Session approval context changed during admission.');
    }
  }
}
