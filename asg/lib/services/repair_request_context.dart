// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/agent_session_binding.dart';
import '../models/build_plan.dart';
import '../models/candidate_verification_run.dart';
import '../models/project.dart';
import '../models/source_generation.dart';
import 'agent_session_admission.dart';
import 'application_store.dart';
import 'candidate_repair_evidence.dart';
import 'generation_input.dart';
import 'plan_approval_store.dart';
import 'record_storage.dart';
import 'requirements_store.dart';

/// Fixed-key captured repair context, not an execution grant or arbitrary CAS map.
final class RepairRequestContext {
  RepairRequestContext._(
    this.records,
    this.project,
    this._failureRecord,
    this._session,
    Map<String, String?> expected,
  ) : expected = Map.unmodifiable(expected);

  factory RepairRequestContext.capture({
    required RecordStorage records,
    required StudioProject project,
    required CandidateVerificationRun failure,
    AgentSessionBinding? sessionBinding,
    String? workingRecord,
  }) {
    final workingKey = 'studio.generation.v1.${project.id}';
    final rawWorking = records.getString(workingKey);
    if (workingRecord != null && workingRecord != rawWorking) {
      throw StateError('Original working record changed before repair.');
    }
    final admission = sessionBinding == null
        ? null
        : AgentSessionRunAdmission(records, project, sessionBinding);
    final sessionRaw = admission?.requireCurrent();
    final value = RepairRequestContext._(
      records,
      project,
      jsonEncode(failure.toJson()),
      admission,
      {
        ...AgentSessionAdmission(records, project).approvalRecords(),
        'studio.candidateChecks.v1.${project.id}': records.getString(
          'studio.candidateChecks.v1.${project.id}',
        ),
        'studio.sourceCandidate.v1.${project.id}': records.getString(
          'studio.sourceCandidate.v1.${project.id}',
        ),
        workingKey: rawWorking,
        if (admission != null) admission.binding.session.storageKey: sessionRaw,
      },
    );
    value.requireCurrent();
    return value;
  }

  final RecordStorage records;
  final StudioProject project;
  final String _failureRecord;
  final AgentSessionRunAdmission? _session;
  final Map<String, String?> expected;
  String get projectId => project.id;
  AgentSessionBinding? get selectedSessionBinding => _session?.binding;
  String? get selectedSessionRecord =>
      expected[_session?.binding.session.storageKey];
  String? get workingRecord => expected['studio.generation.v1.$projectId'];

  bool matchesFailure(CandidateVerificationRun failure) =>
      jsonEncode(failure.toJson()) == _failureRecord;

  void requireCurrent() {
    final failure = CandidateVerificationRun.fromJson(
      jsonDecode(_failureRecord) as Map<String, dynamic>,
    );
    requireRepairFailure(
      records,
      project.id,
      failure.snapshot,
      expected: failure,
    );
    final approval = PlanApprovalStore(records).requireCurrentApproval(project);
    if (failure.snapshot.approval?.matches(approval) != true ||
        !BuildPlan.parse(
          approval.content,
          board: RequirementsStore(records).load(project.id),
        ).matchesTasks(failure.snapshot.tasks) ||
        GenerationInput(
              project,
              ApplicationStore(records).load(project).definition,
            ).compare(failure.snapshot) !=
            GeneratedSnapshotStatus.current) {
      throw StateError('Repair approval or recorded inputs changed.');
    }
    _session?.requireCurrent();
    if (expected.entries.any((e) => records.getString(e.key) != e.value)) {
      throw StateError('Repair request context changed.');
    }
  }
}
