// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:async';

import 'package:asg/models/build_plan.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/repair_attempt_store.dart';

import 'source_candidate_controller_test.dart' show AtomicRecords;

import 'package:asg/services/candidate_repair_evidence.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approved_source_proposer_test.dart'
    show seed, serviceFor, originals, response;
import 'candidate_failure_test.dart' show failure;
import 'planning_conversation_test.dart' show ControlledRecords, project, tick;
import 'source_edit_proposer_test.dart' show FakeProvider;

GeneratedProject boundFailure(ControlledRecords records, {String? output}) {
  final approval = PlanApprovalStore(records).load(project.id)!;
  final value = failure();
  final tasks = BuildPlan.parse(
    approval.content,
    board: RequirementsStore(records).load(project.id),
  ).tasks;
  return GeneratedProject(
    directory: value.directory,
    sdk: value.sdk,
    python: value.python,
    confined: true,
    checkpointVersion: 1,
    phase: value.phase,
    sources: {
      ...GenerationInput(
        project,
        ApplicationStore(records).load(project).definition,
      ).fingerprints,
      ...value.sources,
    },
    approval: approval,
    tasks: tasks,
    steps: [
      for (final task in tasks.takeWhile(
        (task) => task.operation.name != 'analyze',
      ))
        GenerationStep(
          operation: task.operation.name,
          exitCode: 0,
          output: 'passed',
        ),
      GenerationStep(
        operation: 'analyze',
        exitCode: 65,
        output: output ?? 'Undefined name at lib/main.dart:7',
      ),
    ],
  );
}

Future<void> saveFailure(
  ControlledRecords records,
  GeneratedProject candidate, {
  bool finished = true,
  int number = 1,
}) async {
  final run = CandidateVerificationRun(
    number: number,
    startedAt: DateTime.utc(2026),
    snapshot: candidate,
    finished: finished,
  );
  await records.setString(
    'studio.sourceCandidate.v1.${project.id}',
    jsonEncode(candidate.toJson()),
  );
  await records.setString(
    'studio.candidateChecks.v1.${project.id}',
    jsonEncode(CandidateVerificationJournal([run]).toJson()),
  );
}

void main() {
  test(
    'cancelled repair request retains saved failure and suppresses publication',
    () async {
      final records = AtomicRecords();
      await seed(records);
      final candidate = boundFailure(records);
      await saveFailure(records, candidate);
      final before = Map.of(records.values);
      final provider = FakeProvider();
      final service = serviceFor(records, provider);
      final pending = service.propose(
        project: project,
        boardTaskId: 'Tanalyze',
        config: const LocalModelConfig(),
        originals: originals,
        repairCandidate: candidate,
      );
      final rejection = expectLater(pending, throwsStateError);
      await tick();
      await service.cancel();
      provider.stream.add(response());
      await provider.stream.close();
      await rejection;
      expect(
        {...records.values}
          ..remove(RepairAttemptStore(records, project.id).key),
        before,
      );
      expect(
        RepairAttemptStore(
          records,
          project.id,
        ).load().attempts.single.status.name,
        'cancelled',
      );
      expect(provider.cancellations, greaterThan(0));
    },
  );
  test('repair request retains actual saved exit, bounded diagnostics and model outcome', () async {
    final records = AtomicRecords();
    await seed(records);
    final candidate = boundFailure(records, output: '${'\u0001' * 6000} END');
    await saveFailure(records, candidate);
    final provider = FakeProvider();
    final service = serviceFor(records, provider);
    final writes = records.writes;
    final pending = service.propose(
      project: project,
      boardTaskId: 'Tanalyze',
      config: const LocalModelConfig(),
      originals: originals,
      repairCandidate: candidate,
    );
    await tick();
    expect(provider.prompt, contains('failedCheck'));
    expect(provider.prompt, contains('exitCode'));
    expect(provider.prompt, contains('65'));
    expect(provider.prompt, contains('untrusted diagnostic data'));
    expect(provider.prompt, isNot(contains(' END')));
    expect(
      jsonEncode(
        repairDiagnostics(requireRepairFailure(records, project.id, candidate)),
      ).length,
      lessThan(3000),
    );
    expect(
      repairDiagnostics(
        requireRepairFailure(records, project.id, candidate),
      )['outputTruncated'],
      isTrue,
    );
    provider.stream.add(response());
    await provider.stream.close();
    final evidence = await pending;
    expect(evidence.repairRun!.snapshot.toJson(), candidate.toJson());
    service.requireCurrent(project, evidence);
    expect(records.writes, writes);
    final attempt = RepairAttemptStore(
      records,
      project.id,
    ).load().attempts.single;
    expect(attempt.status.name, 'proposed');
    expect(
      attempt.proposal!.changes.single.after,
      evidence.proposal.changes.single.after,
    );
    expect(attempt.failure.snapshot.steps.last.exitCode, 65);
  });

  test(
    'non-source, uncertain, unsaved and mismatched failures refuse inference',
    () async {
      final records = AtomicRecords();
      await seed(records);
      final valid = boundFailure(records);
      for (final candidate in [
        failure(operation: 'resolve'),
        failure(cancelled: true),
        failure(timedOut: true),
        failure(outputLimitExceeded: true),
        failure(exitCode: -9),
        valid.copy(steps: [valid.steps.first], pendingOperation: 'analyze'),
        valid.copy(
          phase: SourceGenerationPhase.verifying,
          steps: [valid.steps.first],
        ),
      ]) {
        await saveFailure(
          records,
          candidate,
          finished: candidate.phase == SourceGenerationPhase.failed,
        );
        final provider = FakeProvider();
        await expectLater(
          serviceFor(records, provider).propose(
            project: project,
            boardTaskId: 'Tanalyze',
            config: const LocalModelConfig(),
            originals: originals,
            repairCandidate: candidate,
          ),
          throwsA(anything),
        );
        expect(provider.prompt, isNull);
      }
      await saveFailure(records, valid);
      await records.setString('studio.sourceCandidate.v1.${project.id}', '{}');
      final provider = FakeProvider();
      await expectLater(
        serviceFor(records, provider).propose(
          project: project,
          boardTaskId: 'Tanalyze',
          config: const LocalModelConfig(),
          originals: originals,
          repairCandidate: valid,
        ),
        throwsStateError,
      );
      expect(provider.prompt, isNull);
    },
  );

  test('superseded failure during inference or cleanup rejects late repair evidence', () async {
    for (final cleanup in [false, true]) {
      final records = AtomicRecords();
      await seed(records);
      final candidate = boundFailure(records);
      await saveFailure(records, candidate);
      final provider = FakeProvider();
      final service = serviceFor(records, provider);
      final pending = service.propose(
        project: project,
        boardTaskId: 'Tanalyze',
        config: const LocalModelConfig(),
        originals: originals,
        repairCandidate: candidate,
      );
      final rejection = expectLater(pending, throwsStateError);
      await tick();
      if (cleanup) {
        provider.cleanup = Completer<void>();
        provider.stream.add(response());
        await provider.stream.close();
        await tick();
      }
      await records.setString('studio.sourceCandidate.v1.${project.id}', '{}');
      await tick();
      if (cleanup) {
        provider.cleanup!.complete();
      } else {
        provider.stream.add(response());
        await provider.stream.close();
      }
      await rejection;
    }
  });
}
