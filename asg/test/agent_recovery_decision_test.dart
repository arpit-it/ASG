// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/agent_execution_checkpoint.dart';
import 'package:asg/models/agent_recovery_decision.dart';
import 'package:flutter_test/flutter_test.dart';

RecoveryDispatchIdentity identity({
  String task = 'task',
  int revision = 3,
  RecoveryOperation operation = RecoveryOperation.test,
  String? source,
  String? approval,
  String host = 'host-session',
}) => RecoveryDispatchIdentity(
  taskId: task,
  dispatchRevision: revision,
  operation: operation,
  sourceFingerprint: source ?? 'a' * 64,
  approvalFingerprint: approval ?? 'b' * 64,
  hostSessionId: host,
);

AgentExecutionCheckpoint executing() =>
    AgentExecutionCheckpoint.create('task')
        .advance(AgentExecutionPhase.planning)
        .advance(AgentExecutionPhase.awaitingApproval)
        .advance(AgentExecutionPhase.executing);

RecoveryObservation observed({
  RecoveryReceiptValidation validation = RecoveryReceiptValidation.validated,
  RecoveryDispatchIdentity? dispatch,
  RecoveryRunnerState runner = RecoveryRunnerState.stopped,
  int? code = 0,
  bool cleanup = true,
  bool cancel = false,
}) => RecoveryObservation(
  validation: validation,
  identity: dispatch ?? identity(),
  runner: runner,
  exitCode: code,
  cleanupConfirmed: cleanup,
  cancellationRequested: cancel,
);

void main() {
  final cases =
      <(String, RecoveryObservation, RecoveryDisposition, RecoveryReason)>[
        (
          'saved intent without launch',
          const RecoveryObservation(
            validation: RecoveryReceiptValidation.missing,
          ),
          RecoveryDisposition.unresolved,
          RecoveryReason.missingReceipt,
        ),
        (
          'untrusted success cannot reconcile',
          observed(validation: RecoveryReceiptValidation.untrusted),
          RecoveryDisposition.unresolved,
          RecoveryReason.untrustedReceipt,
        ),
        (
          'missing identity',
          const RecoveryObservation(
            validation: RecoveryReceiptValidation.validated,
          ),
          RecoveryDisposition.unresolved,
          RecoveryReason.identityMismatch,
        ),
        (
          'PID reused',
          observed(runner: RecoveryRunnerState.identityMismatch),
          RecoveryDisposition.unresolved,
          RecoveryReason.identityMismatch,
        ),
        (
          'runner absent proves no result',
          observed(code: null),
          RecoveryDisposition.unresolved,
          RecoveryReason.missingResult,
        ),
        (
          'unknown cleanup',
          observed(code: 7, cleanup: false),
          RecoveryDisposition.unresolved,
          RecoveryReason.unknownCleanup,
        ),
        (
          'runner state unknown',
          observed(runner: RecoveryRunnerState.unknown, code: 7),
          RecoveryDisposition.unresolved,
          RecoveryReason.unknownRunner,
        ),
        (
          'owned runner still active',
          observed(
            runner: RecoveryRunnerState.ownedRunning,
            code: null,
            cleanup: false,
          ),
          RecoveryDisposition.observeOwnedRunner,
          RecoveryReason.runnerStillActive,
        ),
        (
          'active runner contradicts exit',
          observed(runner: RecoveryRunnerState.ownedRunning, cleanup: false),
          RecoveryDisposition.unresolved,
          RecoveryReason.contradictoryEvidence,
        ),
        (
          'active runner contradicts cleanup',
          observed(runner: RecoveryRunnerState.ownedRunning, code: null),
          RecoveryDisposition.unresolved,
          RecoveryReason.contradictoryEvidence,
        ),
        (
          'lost completion with validated result',
          observed(),
          RecoveryDisposition.resultReady,
          RecoveryReason.retainedResult,
        ),
        (
          'failed result remains failed',
          observed(code: 7),
          RecoveryDisposition.resultReady,
          RecoveryReason.retainedResult,
        ),
        (
          'cancellation retains observed exit',
          observed(code: -1, cancel: true),
          RecoveryDisposition.resultReady,
          RecoveryReason.retainedResult,
        ),
        (
          'cancel before result',
          observed(code: null, cleanup: false, cancel: true),
          RecoveryDisposition.unresolved,
          RecoveryReason.missingResult,
        ),
      ];
  for (final (name, observation, disposition, reason) in cases) {
    test(name, () {
      final checkpoint = executing();
      final before = checkpoint.toJson();
      final decision = AgentRecoveryDecision.inspect(
        checkpoint: checkpoint,
        expected: identity(),
        observation: observation,
      );
      expect(decision.disposition, disposition);
      expect(decision.reason, reason);
      expect(decision.explanation, isNotEmpty);
      expect(decision.cancellationRequested, observation.cancellationRequested);
      if (reason == RecoveryReason.retainedResult ||
          reason == RecoveryReason.unknownCleanup ||
          reason == RecoveryReason.unknownRunner) {
        expect(decision.exitCode, observation.exitCode);
      } else {
        expect(decision.exitCode, isNull);
      }
      expect(checkpoint.toJson(), before);
    });
  }

  final changed = [
    identity(task: 'other'),
    identity(revision: 4),
    identity(operation: RecoveryOperation.build),
    identity(source: 'c' * 64),
    identity(approval: 'c' * 64),
    identity(host: 'new-session'),
  ];
  for (var i = 0; i < changed.length; i++) {
    test('identity dimension $i rejects delayed receipt', () {
      final decision = AgentRecoveryDecision.inspect(
        checkpoint: executing(),
        expected: identity(),
        observation: observed(dispatch: changed[i]),
      );
      expect(decision.disposition, RecoveryDisposition.unresolved);
      expect(decision.reason, RecoveryReason.identityMismatch);
      expect(decision.exitCode, isNull);
    });
  }

  test('stale expected dispatch cannot reconcile current checkpoint', () {
    final decision = AgentRecoveryDecision.inspect(
      checkpoint: executing(),
      expected: identity(revision: 2),
      observation: observed(dispatch: identity(revision: 2)),
    );
    expect(decision.reason, RecoveryReason.staleDispatch);
    expect(decision.disposition, RecoveryDisposition.unresolved);
  });

  test('recovering checkpoint keeps original dispatch identity', () {
    final decision = AgentRecoveryDecision.inspect(
      checkpoint: executing().advance(AgentExecutionPhase.recovering),
      expected: identity(),
      observation: observed(),
    );
    expect(decision.disposition, RecoveryDisposition.resultReady);
  });

  test('terminal checkpoints ignore stale or absent observations', () {
    final completed = executing()
        .advance(AgentExecutionPhase.verifying)
        .advance(AgentExecutionPhase.reviewing)
        .advance(AgentExecutionPhase.completed);
    final cancelled = AgentExecutionCheckpoint.create('task')
        .advance(AgentExecutionPhase.cancelled);
    for (final checkpoint in [completed, cancelled]) {
      for (final observation in [
        observed(dispatch: identity(host: 'wrong')),
        const RecoveryObservation(
          validation: RecoveryReceiptValidation.missing,
        ),
      ]) {
        final decision = AgentRecoveryDecision.inspect(
          checkpoint: checkpoint,
          expected: identity(),
          observation: observation,
        );
        expect(decision.disposition, RecoveryDisposition.terminal);
        expect(decision.exitCode, isNull);
      }
    }
  });

  test('non-pending phases cannot consume receipt as new authority', () {
    final checkpoint = executing().advance(AgentExecutionPhase.verifying);
    final decision = AgentRecoveryDecision.inspect(
      checkpoint: checkpoint,
      expected: identity(),
      observation: observed(),
    );
    expect(decision.disposition, RecoveryDisposition.notPending);
    expect(decision.exitCode, isNull);
  });

  test('invalid identities fail before classification', () {
    for (final make in <RecoveryDispatchIdentity Function()>[
      () => identity(task: '../task'),
      () => identity(revision: 0),
      () => identity(host: ''),
      () => identity(source: 'unvalidated'),
      () => identity(approval: 'B' * 64),
    ]) {
      expect(make, throwsArgumentError);
    }
  });
}
