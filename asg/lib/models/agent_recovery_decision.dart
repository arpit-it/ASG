// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'agent_execution_checkpoint.dart';

/// The existing fixed candidate operations; this grants no execution authority.
enum RecoveryOperation { resolve, analyze, test, build }

final class RecoveryDispatchIdentity {
  RecoveryDispatchIdentity({
    required this.taskId,
    required this.dispatchRevision,
    required this.operation,
    required this.sourceFingerprint,
    required this.approvalFingerprint,
    required this.hostSessionId,
  }) {
    if (!AgentExecutionCheckpoint.isValidTaskId(taskId) ||
        dispatchRevision < 1 ||
        !AgentExecutionCheckpoint.isValidTaskId(hostSessionId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sourceFingerprint) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(approvalFingerprint)) {
      throw ArgumentError('Invalid recovery dispatch identity.');
    }
  }

  final String taskId, sourceFingerprint, approvalFingerprint, hostSessionId;
  final int dispatchRevision;
  final RecoveryOperation operation;
  String get dispatchId => '$taskId:$dispatchRevision';

  bool matches(RecoveryDispatchIdentity other) =>
      taskId == other.taskId &&
      dispatchRevision == other.dispatchRevision &&
      operation == other.operation &&
      sourceFingerprint == other.sourceFingerprint &&
      approvalFingerprint == other.approvalFingerprint &&
      hostSessionId == other.hostSessionId;
}

enum RecoveryReceiptValidation { missing, untrusted, validated }

enum RecoveryRunnerState { unknown, ownedRunning, stopped, identityMismatch }

/// Caller-supplied observations, not proof of receipt authentication or ownership.
/// A future trusted service must validate the publisher before using `validated`.
final class RecoveryObservation {
  const RecoveryObservation({
    required this.validation,
    this.identity,
    this.runner = RecoveryRunnerState.unknown,
    this.exitCode,
    this.cleanupConfirmed = false,
    this.cancellationRequested = false,
  });

  final RecoveryReceiptValidation validation;
  final RecoveryDispatchIdentity? identity;
  final RecoveryRunnerState runner;
  final int? exitCode;
  final bool cleanupConfirmed, cancellationRequested;
}

enum RecoveryDisposition {
  terminal,
  notPending,
  unresolved,
  observeOwnedRunner,
  resultReady,
}

enum RecoveryReason {
  terminalCheckpoint,
  noPendingDispatch,
  staleDispatch,
  missingReceipt,
  untrustedReceipt,
  identityMismatch,
  contradictoryEvidence,
  runnerStillActive,
  unknownRunner,
  missingResult,
  unknownCleanup,
  retainedResult,
}

/// Descriptive only: no disposition authorizes replay, process control or a write.
/// `resultReady` still requires the service's atomic revision/approval checks.
final class AgentRecoveryDecision {
  const AgentRecoveryDecision._(
    this.disposition,
    this.reason, {
    this.exitCode,
    required this.cancellationRequested,
  });

  final RecoveryDisposition disposition;
  final RecoveryReason reason;
  final int? exitCode;
  final bool cancellationRequested;

  String get explanation => switch (reason) {
    RecoveryReason.terminalCheckpoint =>
      'This execution is terminal. Keep its saved result.',
    RecoveryReason.noPendingDispatch =>
      'No interrupted dispatch requires reconciliation.',
    RecoveryReason.staleDispatch =>
      'The saved execution no longer matches this dispatch.',
    RecoveryReason.missingReceipt =>
      'Launch or completion evidence is missing. The outcome remains unknown.',
    RecoveryReason.untrustedReceipt =>
      'Runner evidence has not been validated. Preserve the interruption.',
    RecoveryReason.identityMismatch =>
      'Runner evidence belongs to a different dispatch or host identity.',
    RecoveryReason.contradictoryEvidence =>
      'Runner activity conflicts with its reported exit or cleanup.',
    RecoveryReason.runnerStillActive =>
      'The matching owned runner is still active. Do not launch a duplicate.',
    RecoveryReason.unknownRunner =>
      'Runner ownership or cessation remains unknown.',
    RecoveryReason.missingResult =>
      'No actual command exit was retained. Keep the outcome unknown.',
    RecoveryReason.unknownCleanup =>
      'The actual exit is retained, but descendant cleanup remains unknown.',
    RecoveryReason.retainedResult => 'A matching result and cleanup observation are ready for atomic reconciliation.',
  };

  static AgentRecoveryDecision inspect({
    required AgentExecutionCheckpoint checkpoint,
    required RecoveryDispatchIdentity expected,
    required RecoveryObservation observation,
  }) {
    AgentRecoveryDecision decision(
      RecoveryDisposition disposition,
      RecoveryReason reason, {
      int? exitCode,
    }) => AgentRecoveryDecision._(
      disposition,
      reason,
      exitCode: exitCode,
      cancellationRequested: observation.cancellationRequested,
    );

    if (checkpoint.phase == AgentExecutionPhase.completed ||
        checkpoint.phase == AgentExecutionPhase.cancelled) {
      return decision(
        RecoveryDisposition.terminal,
        RecoveryReason.terminalCheckpoint,
      );
    }
    if (!checkpoint.requiresReconciliation) {
      return decision(
        RecoveryDisposition.notPending,
        RecoveryReason.noPendingDispatch,
      );
    }
    if (checkpoint.dispatchId != expected.dispatchId) {
      return decision(
        RecoveryDisposition.unresolved,
        RecoveryReason.staleDispatch,
      );
    }
    if (observation.validation != RecoveryReceiptValidation.validated) {
      return decision(
        RecoveryDisposition.unresolved,
        observation.validation == RecoveryReceiptValidation.missing
            ? RecoveryReason.missingReceipt
            : RecoveryReason.untrustedReceipt,
      );
    }
    final observed = observation.identity;
    if (observed == null ||
        !expected.matches(observed) ||
        observation.runner == RecoveryRunnerState.identityMismatch) {
      return decision(
        RecoveryDisposition.unresolved,
        RecoveryReason.identityMismatch,
      );
    }
    if (observation.runner == RecoveryRunnerState.ownedRunning) {
      if (observation.exitCode != null || observation.cleanupConfirmed) {
        return decision(
          RecoveryDisposition.unresolved,
          RecoveryReason.contradictoryEvidence,
        );
      }
      return decision(
        RecoveryDisposition.observeOwnedRunner,
        RecoveryReason.runnerStillActive,
      );
    }
    if (observation.runner != RecoveryRunnerState.stopped) {
      return decision(
        RecoveryDisposition.unresolved,
        RecoveryReason.unknownRunner,
        exitCode: observation.exitCode,
      );
    }
    if (observation.exitCode == null) {
      return decision(
        RecoveryDisposition.unresolved,
        RecoveryReason.missingResult,
      );
    }
    if (!observation.cleanupConfirmed) {
      return decision(
        RecoveryDisposition.unresolved,
        RecoveryReason.unknownCleanup,
        exitCode: observation.exitCode,
      );
    }
    return decision(
      RecoveryDisposition.resultReady,
      RecoveryReason.retainedResult,
      exitCode: observation.exitCode,
    );
  }
}
