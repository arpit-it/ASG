// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'agent_execution_checkpoint.dart';
import 'candidate_operation_receipt.dart';
import 'candidate_stop_request.dart';
import 'candidate_verification_run.dart';

enum CandidateRecoveryEvidence { loading, unavailable, readable }

enum CandidateRecoveryReason {
  executionUnavailable,
  loading,
  evidenceUnavailable,
  missingExit,
  retainedExit,
}

/// Describes saved observations only; never authorizes effects or verifies cleanup.
final class CandidateRecoveryStatus {
  const CandidateRecoveryStatus._(
    this.operation,
    this.reason,
    this.exitCode,
    this.stopRequested,
    this.stopEvidenceUnavailable,
  );

  final String operation;
  final CandidateRecoveryReason reason;
  final int? exitCode;
  final bool stopRequested, stopEvidenceUnavailable;

  String get explanation {
    final observation = switch (reason) {
      CandidateRecoveryReason.executionUnavailable => 'Saved execution identity is unavailable or changed. This operation remains unresolved.',
      CandidateRecoveryReason.loading =>
        'Loading saved completion evidence. This operation remains unresolved.',
      CandidateRecoveryReason.evidenceUnavailable => 'Saved completion evidence is unavailable or does not match. This operation remains unresolved.',
      CandidateRecoveryReason.missingExit =>
        'No actual exit was retained for $operation. Its outcome remains unknown.',
      CandidateRecoveryReason.retainedExit =>
        'The retained $operation exit is $exitCode. Runner activity and cleanup remain unknown.',
    };
    final stop = stopRequested
        ? ' A Stop request is saved; it does not confirm exit or cleanup.'
        : stopEvidenceUnavailable
        ? ' Saved Stop evidence is unavailable.'
        : '';
    return '$observation$stop';
  }

  static String _hash(Object? value) =>
      sha256.convert(utf8.encode(jsonEncode(value))).toString();

  /// Same input projection as private completion receipt storage, without I/O.
  static Map<String, String> fingerprints(CandidateVerificationRun run) {
    final snapshot = run.snapshot;
    final sources = Map.fromEntries(
      snapshot.sources.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    final approval = snapshot.approval?.toJson();
    return {
      'source': _hash(sources),
      'approval': _hash(approval),
      'execution': _hash({
        'directory': path.normalize(snapshot.directory),
        'sdk': path.normalize(snapshot.sdk),
        'python': snapshot.python,
        'confined': snapshot.confined,
        'checkpointVersion': snapshot.checkpointVersion,
        'sources': sources,
        'approval': approval,
        'limits': snapshot.limits.toJson(),
        'tasks': snapshot.tasks?.map((task) => task.toJson()).toList(),
      }),
    };
  }

  static bool sameRun(CandidateVerificationRun a, CandidateVerificationRun b) =>
      a.number == b.number &&
      a.startedAt == b.startedAt &&
      a.dispatchId == b.dispatchId &&
      a.finished == b.finished &&
      a.snapshot.pendingOperation == b.snapshot.pendingOperation &&
      fingerprints(a)['execution'] == fingerprints(b)['execution'];

  static CandidateRecoveryStatus? inspect({
    required String projectId,
    required CandidateVerificationRun run,
    required AgentExecutionCheckpoint? execution,
    required List<CandidateOperationReceipt> receipts,
    required CandidateRecoveryEvidence evidence,
    CandidateStopRequest? stop,
    bool stopEvidenceUnavailable = false,
  }) {
    final operation = run.snapshot.pendingOperation;
    if (run.finished ||
        !const ['resolve', 'analyze', 'test', 'build'].contains(operation)) {
      return null;
    }
    final stopRequested = stop?.matches(projectId, run) == true;
    CandidateRecoveryStatus status(
      CandidateRecoveryReason reason, [
      int? exit,
    ]) => CandidateRecoveryStatus._(
      operation,
      reason,
      exit,
      stopRequested,
      stopEvidenceUnavailable || (stop != null && !stopRequested),
    );
    if (run.dispatchId == null ||
        execution == null ||
        !execution.requiresReconciliation ||
        execution.dispatchId != run.dispatchId) {
      return status(CandidateRecoveryReason.executionUnavailable);
    }
    if (evidence == CandidateRecoveryEvidence.loading) {
      return status(CandidateRecoveryReason.loading);
    }
    final expected = fingerprints(run);
    if (evidence == CandidateRecoveryEvidence.unavailable ||
        receipts.any(
          (receipt) =>
              receipt.context.dispatchId != run.dispatchId ||
              receipt.context.sourceFingerprint != expected['source'] ||
              receipt.context.approvalFingerprint != expected['approval'] ||
              receipt.context.executionFingerprint != expected['execution'],
        )) {
      return status(CandidateRecoveryReason.evidenceUnavailable);
    }
    final target = receipts
        .where((receipt) => receipt.operation.name == operation)
        .toList();
    if (target.length > 1) {
      return status(CandidateRecoveryReason.evidenceUnavailable);
    }
    return target.isEmpty
        ? status(CandidateRecoveryReason.missingExit)
        : status(
            CandidateRecoveryReason.retainedExit,
            target.single.result.exitCode,
          );
  }
}
