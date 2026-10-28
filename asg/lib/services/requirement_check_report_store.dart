// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../models/build_plan.dart';
import '../models/manual_check_observation.dart';
import '../models/named_check_observation.dart';
import '../models/named_flutter_test_result.dart';
import '../models/requirements_board.dart';
import '../models/build_task.dart';
import '../models/project.dart';
import '../models/requirement_check_report.dart';
import '../models/source_generation.dart';
import 'application_store.dart';
import 'manual_check_observation_store.dart';
import 'named_check_observation_store.dart';
import 'generation_input.dart';
import 'plan_approval_store.dart';
import 'record_storage.dart';
import 'requirements_store.dart';
import 'source_generation_store.dart';

/// Read-only deterministic mapping. Exceptions are rendered by the controller.
class RequirementCheckReportStore {
  RequirementCheckReportStore(this.records);
  final RecordStorage records;
  Future<void> recordManualObservation(
    StudioProject project,
    RequirementCheckReport selected,
    String requirementId,
    String checkId,
    bool passed,
    DateTime observedAt, {
    required bool Function() authorized,
  }) async {
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw StateError('Manual observations require transactional storage.');
    }
    final current = load(project);
    final requirement = current.results
        .where((r) => r.requirement.id == requirementId)
        .firstOrNull;
    final check = requirement?.requirement.checks
        .where((c) => c.id == checkId)
        .firstOrNull;
    final run = current.revisionIdentity?.savedRunSha256;
    if (current.snapshotFingerprint != selected.snapshotFingerprint ||
        !current.canRecordManualObservation ||
        requirement == null ||
        check?.type != AcceptanceCheckType.manual ||
        run == null) {
      throw StateError(
        'Reload current successful evidence and choose an authored manual check.',
      );
    }
    final target = ManualCheckObservationStore.key(project.id);
    final expected = <String, String?>{
      for (final key in [
        target,
        ManualCheckObservationStore.key(project.id),
        NamedCheckObservationStore.key(project.id),
        'studio.projects.v1',
        RequirementsStore.key(project.id),
        'studio.generation.v1.${project.id}',
        'studio.application.v1.${project.id}',
        'studio.planApproval.v1.${project.id}',
        'studio.chat.v1.${project.id}',
      ])
        key: records.getString(key),
    };
    final values = [
      for (final value in current.manualObservations)
        if (value.requirementId != requirementId || value.checkId != checkId)
          value,
      ManualCheckObservation(
        requirementId: requirementId,
        checkId: checkId,
        requirementSha256: requirement.acceptance.requirementSha256,
        runSha256: run,
        passed: passed,
        observedAt: observedAt.toUtc(),
      ),
    ];
    await storage.commitRecords(
      expected: expected,
      updates: {target: ManualCheckObservationStore.encode(values)},
      authorize: () {
        if (!authorized()) {
          throw StateError('Observation was cancelled before saving.');
        }
      },
    );
  }

  Future<void> recordNamedTestResult(
    StudioProject project,
    RequirementCheckReport selected,
    String requirementId,
    String checkId,
    NamedFlutterTestResult result,
    DateTime observedAt, {
    required bool Function() authorized,
  }) async {
    final storage = records;
    if (storage is! ConditionalRecordStorage) {
      throw StateError('Named results require transactional storage.');
    }
    final current = load(project);
    final requirement = current.results
        .where((r) => r.requirement.id == requirementId)
        .firstOrNull;
    final check = requirement?.requirement.checks
        .where((c) => c.id == checkId)
        .firstOrNull;
    final run = current.revisionIdentity?.savedRunSha256;
    if (current.snapshotFingerprint != selected.snapshotFingerprint ||
        !current.canRecordManualObservation ||
        requirement == null ||
        check?.type != AcceptanceCheckType.automated ||
        check?.target?.file != result.target.file ||
        check?.target?.name != result.target.name ||
        run == null) {
      throw StateError(
        'Reload current successful evidence and choose its authored automated target.',
      );
    }
    final target = NamedCheckObservationStore.key(project.id);
    final expected = <String, String?>{
      for (final key in [
        target,
        ManualCheckObservationStore.key(project.id),
        NamedCheckObservationStore.key(project.id),
        'studio.projects.v1',
        RequirementsStore.key(project.id),
        'studio.generation.v1.${project.id}',
        'studio.application.v1.${project.id}',
        'studio.planApproval.v1.${project.id}',
        'studio.chat.v1.${project.id}',
      ])
        key: records.getString(key),
    };
    final values = [
      for (final value in current.namedObservations)
        if (value.requirementId != requirementId || value.checkId != checkId)
          value,
      NamedCheckObservation(
        requirementId: requirementId,
        checkId: checkId,
        requirementSha256: requirement.acceptance.requirementSha256,
        runSha256: run,
        result: result,
        observedAt: observedAt.toUtc(),
      ),
    ];
    await storage.commitRecords(
      expected: expected,
      updates: {target: NamedCheckObservationStore.encode(values)},
      authorize: () {
        if (!authorized()) {
          throw StateError('Observation was cancelled before saving.');
        }
      },
    );
  }

  RequirementCheckReport load(StudioProject project) {
    final board = RequirementsStore(records).load(project.id);
    final observations = ManualCheckObservationStore(records).load(project.id);
    final named = NamedCheckObservationStore(records).load(project.id);
    final generation = SourceGenerationStore(records);
    final saved = generation.load(project.id);
    final history = generation.history(project.id);
    final input = GenerationInput(
      project,
      ApplicationStore(records).load(project).definition,
    );
    final approvalSha256 = saved?.approval == null
        ? null
        : sha256
              .convert(utf8.encode(jsonEncode(saved!.approval!.toJson())))
              .toString();
    final identity = RequirementRunIdentity(
      sources: saved?.sources ?? const {},
      currentInputs: input.fingerprints,
      approvalSha256: approvalSha256,
    );
    var current = false;
    if (saved != null) {
      // A withdrawn/replaced approval or changed board/prototype is stale even
      // when command exits were zero. Never infer mapping from model prose.
      try {
        final approval = PlanApprovalStore(records)
            .requireCurrentApproval(project);
        current =
            saved.approval != null &&
            saved.approval!.matches(approval) &&
            input.compare(saved) == GeneratedSnapshotStatus.current &&
            BuildPlan.parse(
              approval.content,
              board: board,
            ).matchesTasks(saved.tasks);
      } on StateError {
        current = false;
      } on FormatException {
        current = false;
      }
    }
    final tasks = saved?.tasks ?? <BuildTask>[];
    final results = [
      for (final requirement in board.requirements)
        () {
          final ids = board.tasks
              .where((t) => t.requirementId == requirement.id)
              .map((t) => t.id)
              .toSet();
          final operations = tasks
              .where((t) => ids.contains(t.boardTaskId))
              .toList();
          final RequirementCheckState state;
          final String reason;
          if (saved == null) {
            state = RequirementCheckState.missing;
            reason = 'No saved working verification.';
          } else if (!current) {
            state = RequirementCheckState.stale;
            reason = 'Saved inputs, approval or task graph do not match the current project.';
          } else if (ids.isEmpty ||
              ids.any((id) => !operations.any((t) => t.boardTaskId == id))) {
            state = RequirementCheckState.missing;
            reason = 'Every requirement task needs an explicit approved operation mapping.';
          } else if (saved.phase == SourceGenerationPhase.failed ||
              saved.steps.any((s) => !s.succeeded) ||
              saved.failedOperation.isNotEmpty) {
            state = RequirementCheckState.failed;
            reason = 'The saved verification failed, was cancelled or exceeded a limit.';
          } else if (saved.phase != SourceGenerationPhase.ready ||
              saved.pendingOperation.isNotEmpty ||
              operations.any(
                (t) =>
                    saved.taskStatus(t, active: false) !=
                    BuildTaskStatus.passed,
              )) {
            state = RequirementCheckState.incomplete;
            reason =
                'Verification has not saved a complete successful outcome.';
          } else {
            state = RequirementCheckState.mappedChecksPassed;
            reason = 'All mapped operations passed in the saved working verification. Acceptance criteria still need review.';
          }
          return RequirementCheckResult(
            requirement,
            state,
            reason,
            ids.toList(),
            operations.map((t) => t.id).toList(),
            checks: [
              for (final task in operations)
                () {
                  final step = saved!.steps
                      .where((s) => s.operation == task.operation.name)
                      .firstOrNull;
                  return RequirementOperationEvidence(
                    taskId: task.id,
                    boardTaskId: task.boardTaskId!,
                    operation: task.operation,
                    status: saved.taskStatus(task, active: false),
                    exitCode: step?.exitCode,
                    timedOut: step?.timedOut ?? false,
                    cancelled: step?.cancelled ?? false,
                    outputLimitExceeded: step?.outputLimitExceeded ?? false,
                  );
                }(),
            ],
          );
        }(),
    ];
    final matchingHistory = saved == null
        ? null
        : history
              .where(
                (e) =>
                    jsonEncode(e.project.toJson()) ==
                    jsonEncode(saved.toJson()),
              )
              .lastOrNull;
    final projection = RequirementCheckReport(
      board.revision,
      results,
      '',
      savedProject: saved,
      revisionIdentity: identity,
      savedInputsCurrent: current,
      manualObservations: observations,
      namedObservations: named,
    );
    return RequirementCheckReport(
      board.revision,
      results,
      const JsonEncoder.withIndent('  ').convert({
        'scope': RequirementCheckReport.limits,
        'requirementsRevision': board.revision,
        'namedObservations': [
          for (final value in named)
            {
              ...value.toJson(),
              'type': 'automatedNamedTest',
              'status': projection.namedObservationCurrent(value)
                  ? (value.result.passed
                        ? 'savedTargetPassed'
                        : 'savedTargetNotPassed')
                  : 'stale',
              'scope': 'Bound to saved content only; no live artifact or acceptance verdict.',
            },
        ],
        'manualObservations': [
          for (final observation in observations)
            {
              ...observation.toJson(),
              'type': 'manual',
              'status': projection.observationCurrent(observation)
                  ? (observation.passed
                        ? 'manuallyReportedPassed'
                        : 'manuallyReportedFailed')
                  : 'stale',
              'scope':
                  'Human observation only; no automated acceptance verdict.',
            },
        ],
        // No record is distinct from a saved, empty board. The canonical
        // model encoding preserves exact authored text and dependency order.
        'requirementsBoard': board.revision == 0 ? null : board.toJson(),
        'requirementsBoardSha256': board.revision == 0
            ? null
            : sha256
                  .convert(utf8.encode(jsonEncode(board.toJson())))
                  .toString(),
        'savedInputsCurrent': current,
        'recordedAt': matchingHistory?.recordedAt?.toUtc().toIso8601String(),
        'phase': saved?.phase.name,
        'approvalFingerprint': saved?.approval == null
            ? null
            : sha256
                  .convert(utf8.encode(jsonEncode(saved!.approval!.toJson())))
                  .toString(),
        'revisionIdentity': identity.toJson(),
        'sourceFingerprints': saved?.sources,
        'outputFingerprints': saved?.outputs,
        'requirements': [
          for (final r in results)
            {
              'id': r.requirement.id,
              'state': r.state.name,
              'acceptanceStatus': 'unverified',
              'acceptanceEvidence': projection.acceptanceEvidence(r),
              'bindingContext': {
                'requirementSha256': r.acceptance.requirementSha256,
                'savedRunSha256': identity.savedRunSha256,
                'savedInputsCurrent': current,
                'scope': 'Binding context only. Manual observations are separate from automated operation evidence.',
              },
              'contextualEvidence': {
                'type': 'automatedOperation',
                'criterionMapping': 'none',
                'operationIds': r.operationIds,
                'state': r.state.name,
              },
              'checks': [for (final check in r.checks) check.toJson()],
              'boardTaskIds': r.taskIds,
              'operationIds': r.operationIds,
            },
        ],
        'operations': [
          for (final t in tasks)
            {
              'id': t.id,
              'boardTaskId': t.boardTaskId,
              'operation': t.operation.name,
              'status': saved!.taskStatus(t, active: false).name,
            },
        ],
        'results': [
          for (final s in saved?.steps ?? <GenerationStep>[])
            {
              'operation': s.operation,
              'exitCode': s.exitCode,
              'timedOut': s.timedOut,
              'cancelled': s.cancelled,
              'outputLimitExceeded': s.outputLimitExceeded,
            },
        ],
      }),
      manualObservations: observations,
      namedObservations: named,
      revisionIdentity: identity,
      savedInputsCurrent: current,
      savedProject: saved,
      snapshotFingerprint: sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'project': project.toJson(),
                'board': board.toJson(),
                'saved': saved?.toJson(),
                'current': current,
                'history': matchingHistory?.toJson(),
                'namedObservations': [for (final v in named) v.toJson()],
                'manualObservations': [
                  for (final v in observations) v.toJson(),
                ],
              }),
            ),
          )
          .toString(),
    );
  }
}
