// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/plan_approval.dart';
import 'package:asg/services/candidate_receipt_native.dart';

import 'package:asg/models/agent_execution_checkpoint.dart';
import 'package:asg/models/candidate_recovery_status.dart';
import 'package:asg/models/candidate_operation_receipt.dart';
import 'package:asg/models/candidate_stop_request.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/source_generation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'candidate_operation_receipt_test.dart' show receiptJson;

final execution = AgentExecutionCheckpoint.create('candidate-p-1')
    .advance(AgentExecutionPhase.planning)
    .advance(AgentExecutionPhase.awaitingApproval)
    .advance(AgentExecutionPhase.executing);
CandidateVerificationRun recoveryRun({
  bool finished = false,
  String pending = 'test',
  String source = 'a',
}) => CandidateVerificationRun(
  number: 1,
  startedAt: DateTime.utc(2026),
  dispatchId: execution.dispatchId,
  finished: finished,
  snapshot: GeneratedProject(
    directory: '/candidate',
    sdk: '/sdk',
    python: 'python3',
    sources: {'lib/main.dart': source * 64},
    confined: true,
    checkpointVersion: 1,
    phase: SourceGenerationPhase.verifying,
    pendingOperation: pending,
  ),
);
CandidateOperationReceipt recoveryReceipt(
  CandidateVerificationRun run, {
  String operation = 'test',
  bool wrongInputs = false,
}) {
  final data = receiptJson();
  final hashes = CandidateRecoveryStatus.fingerprints(run);
  final context = data['context'] as Map<String, Object>;
  context['dispatchId'] = run.dispatchId!;
  context['sourceFingerprint'] = wrongInputs ? 'f' * 64 : hashes['source']!;
  context['approvalFingerprint'] = hashes['approval']!;
  context['executionFingerprint'] = hashes['execution']!;
  data['operation'] = operation;
  return CandidateOperationReceipt.fromJson(data);
}

CandidateRecoveryStatus? inspect(
  CandidateVerificationRun run, {
  List<CandidateOperationReceipt> receipts = const [],
  CandidateRecoveryEvidence evidence = CandidateRecoveryEvidence.readable,
  AgentExecutionCheckpoint? saved,
  CandidateStopRequest? stop,
}) => CandidateRecoveryStatus.inspect(
  projectId: 'p',
  run: run,
  execution: saved ?? execution,
  receipts: receipts,
  evidence: evidence,
  stop: stop,
);
void main() {
  test(
    'summary input identity matches actual native receipt preparation',
    () async {
      final temporary = await Directory.systemTemp.createTemp(
        'asg-recovery-summary-',
      );
      addTearDown(() => temporary.delete(recursive: true));
      final root = await temporary.resolveSymbolicLinks();
      final candidate = await Directory('$root/candidate').create();
      final sdk = await Directory('$root/sdk').create();
      final run = CandidateVerificationRun(
        number: 1,
        startedAt: DateTime.utc(2026),
        dispatchId: execution.dispatchId,
        finished: false,
        snapshot: GeneratedProject(
          directory: candidate.path,
          sdk: sdk.path,
          python: 'python3',
          sources: {'lib/main.dart': 'a' * 64},
          confined: true,
          checkpointVersion: 1,
          phase: SourceGenerationPhase.verifying,
          pendingOperation: 'test',
          approval: PlanApproval(
            messageIndex: 0,
            content: 'fixture',
            context: 'fixture',
            approved: true,
            recordedAt: DateTime.utc(2026),
          ),
        ),
      );
      final files = CandidateReceiptFiles(
        root: () async => Directory('$root/receipts'),
      );
      final directory = await files.prepare(run, () {});
      final context = jsonDecode(
        await File('$directory/context.json').readAsString(),
      );
      final data = receiptJson()..['context'] = context;
      final status = inspect(
        run,
        receipts: [CandidateOperationReceipt.fromJson(data)],
      )!;
      expect(status.reason, CandidateRecoveryReason.retainedExit);
      expect(status.exitCode, -1);
    },
    skip: !Platform.isMacOS,
  );

  test('only interrupted fixed operations have summaries', () {
    expect(inspect(recoveryRun(finished: true)), isNull);
    expect(inspect(recoveryRun(pending: '')), isNull);
    expect(inspect(recoveryRun(pending: 'private-command')), isNull);
  });
  test(
    'actual exit is distinct from unknown cleanup and Stop without mutation',
    () {
      final run = recoveryRun();
      final before = jsonEncode(run.toJson());
      final status = inspect(
        run,
        receipts: [recoveryReceipt(run)],
        stop: CandidateStopRequest.create('p', run, DateTime.utc(2026, 2)),
      )!;
      expect(status.reason, CandidateRecoveryReason.retainedExit);
      expect(status.exitCode, -1);
      expect(status.stopRequested, isTrue);
      expect(status.explanation, contains('cleanup remain unknown'));
      expect(status.explanation, contains('does not confirm exit'));
      expect(jsonEncode(run.toJson()), before);
    },
  );
  test('earlier receipt cannot supply pending exit', () {
    final run = recoveryRun();
    final status = inspect(
      run,
      receipts: [recoveryReceipt(run, operation: 'resolve')],
    )!;
    expect(status.reason, CandidateRecoveryReason.missingExit);
    expect(status.exitCode, isNull);
  });
  test('loading and unavailable evidence never fabricate exits', () {
    for (final state in [
      CandidateRecoveryEvidence.loading,
      CandidateRecoveryEvidence.unavailable,
    ]) {
      final run = recoveryRun();
      final status = inspect(
        run,
        receipts: [recoveryReceipt(run)],
        evidence: state,
      )!;
      expect(status.exitCode, isNull);
      expect(
        status.reason,
        state == CandidateRecoveryEvidence.loading
            ? CandidateRecoveryReason.loading
            : CandidateRecoveryReason.evidenceUnavailable,
      );
    }
  });
  test('wrong inputs and duplicate results fail closed', () {
    final run = recoveryRun();
    for (final receipts in [
      [recoveryReceipt(run, wrongInputs: true)],
      [recoveryReceipt(run), recoveryReceipt(run)],
    ]) {
      final status = inspect(run, receipts: receipts)!;
      expect(status.reason, CandidateRecoveryReason.evidenceUnavailable);
      expect(status.exitCode, isNull);
    }
  });
  test('missing or later execution does not reconcile interruption', () {
    final run = recoveryRun();
    final missing = CandidateRecoveryStatus.inspect(
      projectId: 'p',
      run: run,
      execution: null,
      receipts: [recoveryReceipt(run)],
      evidence: CandidateRecoveryEvidence.readable,
    )!;
    expect(missing.reason, CandidateRecoveryReason.executionUnavailable);
    expect(
      inspect(
        run,
        saved: execution.advance(AgentExecutionPhase.verifying),
      )!.reason,
      CandidateRecoveryReason.executionUnavailable,
    );
  });
  test('stale Stop and changed run inputs are not reused', () {
    final run = recoveryRun();
    final changed = recoveryRun(source: 'b');
    expect(CandidateRecoveryStatus.sameRun(run, changed), isFalse);
    final status = inspect(
      changed,
      stop: CandidateStopRequest.create('p', run, DateTime.utc(2026, 2)),
    )!;
    expect(status.stopRequested, isFalse);
    expect(status.stopEvidenceUnavailable, isTrue);
  });
}
