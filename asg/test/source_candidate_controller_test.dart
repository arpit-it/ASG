// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/services/agent_execution_checkpoint_store.dart';

import 'package:asg/controllers/source_candidate_controller.dart';
import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/candidate_failure.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/candidate_operation_receipt.dart';
import 'package:asg/models/candidate_recovery_status.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/generation_host.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:asg/views/source_candidate_view.dart';

import 'candidate_operation_receipt_test.dart' show receiptJson;
import 'approved_source_proposer_test.dart' show seed;
import 'board_mapped_build_plan_test.dart' show boardContent, boardContract;
import 'planning_conversation_test.dart' show ControlledRecords, project, tick;
import 'source_generation_controller_test.dart' show FixtureHost;

class AtomicRecords extends ControlledRecords
    implements ConditionalRecordStorage {
  bool failCommit = false;
  Future<void> Function()? beforeCommit;
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    await beforeCommit?.call();
    if (failCommit || expected.entries.any((e) => values[e.key] != e.value)) {
      throw StateError('Atomic publication refused');
    }
    authorize();
    for (final e in updates.entries) {
      StudioDatabase.validate(e.key, e.value);
    }
    values.addAll(updates);
  }
}

class InterruptedCheckHost extends FixtureHost {
  late void Function() stop;

  @override
  Future<GeneratedProject> verify(
    GeneratedProject project,
    GenerationProgress progress, {
    bool resume = false,
  }) async {
    await progress(project.copy(pendingOperation: 'resolve'));
    stop();
    throw StateError('Command outcome unavailable');
  }
}

class FailingStopSignalHost extends InterruptedCheckHost {
  bool failNextSignal = true;
  @override
  void cancelVerification() {
    super.cancelVerification();
    if (failNextSignal) {
      failNextSignal = false;
      throw StateError('private runtime signal failure');
    }
  }
}

class ReceiptCheckHost extends InterruptedCheckHost
    implements CandidateReceiptHost {
  bool failPreparation = false, failRead = false, mismatch = false;
  int preparations = 0, reads = 0;
  CandidateVerificationRun? prepared;
  Completer<List<CandidateOperationReceipt>>? deferred;
  Completer<void>? preparation;

  CandidateOperationReceipt receipt(CandidateVerificationRun run) {
    final data = receiptJson();
    (data['context'] as Map<String, Object>)['dispatchId'] = mismatch
        ? 'other:3'
        : run.dispatchId!;
    final hashes = CandidateRecoveryStatus.fingerprints(run);
    final context = data['context'] as Map<String, Object>;
    context['sourceFingerprint'] = hashes['source']!;
    context['approvalFingerprint'] = hashes['approval']!;
    context['executionFingerprint'] = hashes['execution']!;
    data['operation'] = 'resolve';
    return CandidateOperationReceipt.fromJson(data);
  }

  @override
  Future<void> prepareCandidateReceipts(
    CandidateVerificationRun run,
    void Function() authorize,
  ) async {
    preparations++;
    authorize();
    if (failPreparation) throw StateError('private receipt path');
    await preparation?.future;
    authorize();
    prepared = run;
  }

  @override
  Future<List<CandidateOperationReceipt>> readCandidateReceipts(
    CandidateVerificationRun run,
  ) async {
    reads++;
    if (failRead) throw StateError('private receipt path');
    if (deferred case final waiting?) return waiting.future;
    return [receipt(run)];
  }
}

class FailedCheckHost extends FixtureHost {
  void Function()? beforeFailure;
  @override
  Future<GeneratedProject> verify(
    GeneratedProject project,
    GenerationProgress progress, {
    bool resume = false,
  }) async {
    verifications++;
    var current = project.copy(
      phase: SourceGenerationPhase.verifying,
      checkpointVersion: 1,
      steps: [],
    );
    await progress(current);
    // Use the actual approved graph, which may run test before analyze.
    for (final task in project.tasks!) {
      operations.add(task.operation.name);
      final failed = task.operation.name == 'analyze';
      current = current.copy(
        phase: failed
            ? SourceGenerationPhase.failed
            : SourceGenerationPhase.verifying,
        steps: [
          ...current.steps,
          GenerationStep(
            operation: task.operation.name,
            exitCode: failed ? 65 : 0,
            output: failed ? 'Undefined name at lib/main.dart:7' : 'passed',
          ),
        ],
      );
      if (failed) beforeFailure?.call();
      await progress(current);
      if (failed) return current;
    }
    throw StateError('Fixture must stop at analyze');
  }
}

class PrivateCleanupHost extends FixtureHost {
  @override
  Future<void> dispose() async {
    await super.dispose();
    throw StateError('private-prompt token=private-token /private/path');
  }
}

void main() {
  late AtomicRecords records;
  late FixtureHost workingHost, candidateHost;
  late SourceGenerationController working;
  late SourceCandidateController candidate;
  late GeneratedProject saved;
  setUp(() async {
    records = AtomicRecords();
    final contract = boardContract();
    final tasks = contract['tasks'] as List;
    final test = tasks[1];
    tasks[1] = tasks[2];
    tasks[2] = test;
    await seed(records, content: boardContent(contract));
    final approval = PlanApprovalStore(records).load(project.id)!;
    final plan = BuildPlan.parse(
      approval.content,
      board: RequirementsStore(records).load(project.id),
    );
    final sources = GenerationInput(
      project,
      ApplicationStore(records).load(project).definition,
    ).fingerprints;
    saved = GeneratedProject(
      directory: '/working',
      sdk: '/sdk',
      python: 'python3',
      sources: sources,
      approval: approval,
      tasks: plan.tasks,
      phase: SourceGenerationPhase.ready,
      steps: [
        for (final task in plan.tasks)
          GenerationStep(
            operation: task.operation.name,
            exitCode: 0,
            output: 'working',
          ),
      ],
      outputs: {'index.html': 'a' * 64, 'main.dart.js': 'b' * 64},
    );
    await SourceGenerationStore(records).save(project.id, saved);
    workingHost = FixtureHost();
    candidateHost = FixtureHost();
    working = SourceGenerationController(
      project: project,
      definition: ApplicationStore(records).load(project).definition,
      store: SourceGenerationStore(records),
      host: workingHost,
    );
    await working.startPreview();
    candidate = SourceCandidateController(
      project: project,
      candidate: GeneratedProject(
        directory: '/candidate',
        sdk: '/sdk',
        python: 'python3',
        sources: sources,
        confined: true,
        approval: approval,
        tasks: plan.tasks,
      ),
      evidence: ApprovedSourceProposal(
        projectId: project.id,
        boardTaskId: 'Tanalyze',
        approval: approval,
        proposal: SourceEditProposal.parse(
          {
            'summary': 'Change',
            'changes': [
              {'path': 'lib/main.dart', 'before': 'a', 'after': 'b'},
            ],
          },
          originals: {'lib/main.dart': 'a'},
        ),
      ),
      records: records,
      host: candidateHost,
      publish: (value, host, guard) =>
          working.promoteCandidate(value, host, guard, expectedWorking: saved),
    );
  });
  tearDown(() {
    if (!candidate.isDisposed) candidate.dispose();
    if (!working.isDisposed) working.dispose();
  });

  const privateFailure = 'private-prompt token=private-token /private/path';
  void expectPrivate(String? message) {
    expect(message, isNotNull);
    for (final marker in ['private-prompt', 'private-token', '/private/path']) {
      expect(message, isNot(contains(marker)));
    }
  }

  test('host exception stays private in diagnostics and saved history; retry succeeds', () async {
    final original = records.values['studio.generation.v1.${project.id}'];
    candidateHost.afterResolve = () async => throw StateError(privateFailure);
    await candidate.verify(approved: true);
    expectPrivate(candidate.error);
    expectPrivate(candidate.result.error);
    expectPrivate(candidate.history.single.snapshot.error);
    expect(candidate.history.single.snapshot.steps, isEmpty);
    expect(candidate.canPromote, isFalse);
    expect(records.values['studio.generation.v1.${project.id}'], original);
    expect(workingHost.server, isTrue);
    candidateHost.afterResolve = null;
    await candidate.verify(approved: true);
    expect(candidate.error, isNull);
    expect(candidate.result.phase, SourceGenerationPhase.ready);
    expect(candidate.history.length, 2);
  });

  test(
    'checkpoint exceptions retain observed exits without private diagnostics',
    () async {
      candidateHost.afterResolve = () async {
        records.beforeCommit = () async => throw StateError(privateFailure);
      };
      await candidate.verify(approved: true);
      expectPrivate(candidate.error);
      expectPrivate(candidate.result.error);
      expect(candidate.error, contains('checkpoint could not be saved'));
      expect(candidate.result.steps.single.operation, 'resolve');
      expect(candidate.result.steps.single.exitCode, 0);
      expect(workingHost.server, isTrue);
      records.beforeCommit = null;
      candidateHost.afterResolve = null;
      await candidate.verify(approved: true);
      expect(candidate.error, isNull);
      expect(candidate.result.phase, SourceGenerationPhase.ready);
    },
  );

  test('promotion exception stays private, preserves working output and allows retry', () async {
    await candidate.verify(approved: true);
    final initial = candidate.result;
    final evidence = candidate.evidence;
    candidate.dispose();
    candidateHost = FixtureHost();
    var failing = true;
    candidate = SourceCandidateController(
      project: project,
      candidate: initial,
      evidence: evidence,
      records: records,
      host: candidateHost,
      publish: (value, host, guard) async {
        if (failing) throw StateError(privateFailure);
        return working.promoteCandidate(
          value,
          host,
          guard,
          expectedWorking: saved,
        );
      },
    );
    expect(await candidate.promote(approved: true), isFalse);
    expectPrivate(candidate.error);
    expect(candidate.canPromote, isTrue);
    expect(working.result!.directory, '/working');
    expect(workingHost.server, isTrue);
    failing = false;
    expect(await candidate.promote(approved: true), isTrue);
    expect(candidate.error, isNull);
    expect(working.result!.directory, '/candidate');
  });

  test(
    'disposed host failure publishes no diagnostic or late notification',
    () async {
      var notifications = 0;
      candidate.addListener(() => notifications++);
      candidateHost.afterResolve = () async {
        candidate.dispose();
        throw StateError(privateFailure);
      };
      await candidate.verify(approved: true);
      expect(candidate.error, isNull);
      expect(notifications, 3);
      expect(workingHost.server, isTrue);
    },
  );

  test(
    'disposed failed promotion contains cleanup failure and clears busy',
    () async {
      await candidate.verify(approved: true);
      final initial = candidate.result;
      final evidence = candidate.evidence;
      candidate.dispose();
      candidateHost = PrivateCleanupHost();
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: candidateHost,
        publish: (value, host, guard) async {
          candidate.dispose();
          throw StateError(privateFailure);
        },
      );
      var notifications = 0;
      candidate.addListener(() => notifications++);
      expect(await candidate.promote(approved: true), isFalse);
      expect(candidate.error, isNull);
      expect(candidate.busy, isFalse);
      expect(candidate.promoting, isFalse);
      expect(candidate.promoted, isFalse);
      expect(notifications, 1);
      expect(candidateHost.disposed, isTrue);
      expect(working.result!.directory, '/working');
      expect(workingHost.server, isTrue);
      expect(
        SourceGenerationStore(records).load(project.id)!.directory,
        '/working',
      );
    },
  );

  test('separate consent, candidate evidence, atomic promotion and host ownership', () async {
    final original = records.getString('studio.generation.v1.${project.id}');
    await candidate.verify(approved: false);
    expect(candidateHost.verifications, 0);
    expect(await candidate.promote(approved: true), isFalse);
    await candidate.verify(approved: true);
    expect(candidate.result.phase, SourceGenerationPhase.ready);
    expect(candidateHost.operations, ['resolve', 'analyze', 'test', 'build']);
    expect(records.getString('studio.generation.v1.${project.id}'), original);
    expect(
      SourceGenerationStore(
        records,
        prefix: 'studio.sourceCandidate.v1.',
      ).load(project.id)!.phase,
      SourceGenerationPhase.ready,
    );
    expect(workingHost.server, isTrue);
    expect(await candidate.promote(approved: false), isFalse);
    final executionKey =
        'studio.agentExecution.v1.${candidate.history.last.dispatchId!.split(':').first}';
    expect(jsonDecode(records.getString(executionKey)!)['phase'], 'verifying');
    expect(await candidate.promote(approved: true), isTrue);
    expect(jsonDecode(records.getString(executionKey)!)['phase'], 'completed');
    SharedPreferences.setMockInitialValues({});
    final folder = await Directory.systemTemp.createTemp(
      'asg-promoted-reopen-',
    );
    try {
      final path = '${folder.path}/studio.db';
      var database = await databaseFactoryIo.openDatabase(path);
      final native = await StudioDatabase.migrate(
        database,
        await SharedPreferences.getInstance(),
      );
      await native.commitRecords(
        expected: {for (final key in records.values.keys) key: null},
        updates: Map<String, String>.from(records.values),
        authorize: () {},
      );
      await database.close();
      database = await databaseFactoryIo.openDatabase(path);
      try {
        final reopened = await StudioDatabase.migrate(
          database,
          await SharedPreferences.getInstance(),
        );
        expect(
          SourceGenerationStore(reopened).load(project.id)!.toJson(),
          candidate.result.toJson(),
        );
        final execution = await AgentExecutionCheckpointStore(reopened)
            .reopen(candidate.history.last.dispatchId!.split(':').first);
        expect(execution!.phase.name, 'completed');
        expect(
          reopened.getString(executionKey),
          records.getString(executionKey),
        );
      } finally {
        await database.close();
      }
    } finally {
      await folder.delete(recursive: true);
    }

    expect(
      records.getString('studio.generationPrevious.v1.${project.id}'),
      original,
    );
    expect(
      SourceGenerationStore(records).load(project.id)!.directory,
      '/candidate',
    );
    final history = SourceGenerationStore(records).history(project.id);
    expect(history.last.project.directory, '/candidate');
    expect(history.last.project.phase, SourceGenerationPhase.ready);
    expect(working.result!.directory, '/candidate');
    expect(working.preview, isNotNull);
    expect(await working.verifyAgain(approved: true), isFalse);
    expect(candidateHost.server, isTrue);
    expect(
      SourceGenerationStore(records).load(project.id)!.phase,
      SourceGenerationPhase.ready,
    );
    candidate.dispose();
    expect(candidateHost.disposed, isFalse);
    await tick();
    expect(workingHost.disposed, isTrue);
    working.dispose();
    expect(candidateHost.disposed, isTrue);
  });

  test('verification failure, cancel, withdrawal and checkpoint failure keep working preview', () async {
    candidateHost.throwAnalyze = true;
    await candidate.verify(approved: true);
    expect(candidate.result.phase, SourceGenerationPhase.failed);
    expect(candidate.result.steps.length, 1);
    expect(candidate.canPromote, isFalse);
    expect(workingHost.server, isTrue);
    expect(working.result!.directory, '/working');
    expect(
      SourceGenerationStore(records).load(project.id)!.directory,
      '/working',
    );
  });

  test(
    'cancel after resolve prevents remaining checks and publication',
    () async {
      candidateHost.afterResolve = () async => candidate.cancel();
      final pending = candidate.verify(approved: true);
      await candidate.verify(approved: true);
      await pending;
      expect(candidateHost.verifications, 1);
      expect(candidateHost.operations, ['resolve']);
      expect(candidate.canPromote, isFalse);
      expect(workingHost.server, isTrue);
      expect(
        SourceGenerationStore(records).load(project.id)!.directory,
        '/working',
      );
    },
  );

  testWidgets(
    'actual failed callback shows conservative diagnosis at 320px and 200%',
    (tester) async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      candidate.dispose();
      candidateHost = FailedCheckHost();
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: candidateHost,
        publish: (value, host, guard) => working.promoteCandidate(
          value,
          host,
          guard,
          expectedWorking: saved,
        ),
      );
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: ListenableBuilder(
              listenable: candidate,
              builder: (_, _) => SingleChildScrollView(
                child: SourceCandidateView(controller: candidate),
              ),
            ),
          ),
        ),
      );
      expect(find.text('Candidate failure diagnosis'), findsNothing);
      await candidate.verify(approved: true);
      await tester.pumpAndSettle();
      expect(
        candidate.failureDiagnosis!.kind,
        CandidateFailureKind.sourceCheckFailure,
      );
      expect(candidate.failureDiagnosis!.step!.exitCode, 65);
      final persisted = SourceGenerationStore(
        records,
        prefix: 'studio.sourceCandidate.v1.',
      ).load(project.id)!;
      expect(
        CandidateFailure.inspect(persisted, active: false)!.message,
        candidate.failureDiagnosis!.message,
      );
      final diagnosis = find.text(candidate.failureDiagnosis!.message);
      await tester.ensureVisible(diagnosis);
      await tester.pumpAndSettle();
      expect(diagnosis, findsOneWidget);
      expect(
        find.textContaining(
          'Source repairs require separate consent in source review.',
        ),
        findsOneWidget,
      );
      expect(candidate.canPromote, isFalse);
      expect(workingHost.server, isTrue);
      expect(working.result!.directory, '/working');
      expect(candidateHost.operations, ['resolve', 'analyze']);
      final history = find.text('Saved candidate check runs');
      await tester.ensureVisible(history);
      await tester.tap(history);
      await tester.pumpAndSettle();
      final run = find.text('Run 1: stopped');
      await tester.ensureVisible(run);
      await tester.tap(run);
      await tester.pumpAndSettle();
      final exit = find.text('analyze: exit 65');
      await tester.ensureVisible(exit);
      await tester.tap(exit);
      await tester.pumpAndSettle();
      expect(find.text('Undefined name at lib/main.dart:7'), findsWidgets);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test(
    'late Stop retains actual failed exit without authorizing more checks',
    () async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      candidate.dispose();
      final failedHost = FailedCheckHost();
      candidateHost = failedHost;
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: candidateHost,
        publish: (value, host, guard) => working.promoteCandidate(
          value,
          host,
          guard,
          expectedWorking: saved,
        ),
      );
      failedHost.beforeFailure = candidate.cancel;
      await candidate.verify(approved: true);
      expect(candidate.history.single.snapshot.steps.last.exitCode, 65);
      expect(
        candidate.history.single.snapshot.steps.last.output,
        contains('Undefined name'),
      );
      expect(candidate.history.single.status, 'stopped');
      expect(candidateHost.operations, ['resolve', 'analyze']);
      expect(candidate.canPromote, isFalse);
      expect(workingHost.server, isTrue);
    },
  );

  test(
    'transient exit checkpoint failure retains observed result in fallback',
    () async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      candidate.dispose();
      final failedHost = FailedCheckHost();
      candidateHost = failedHost;
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: candidateHost,
        publish: (value, host, guard) => working.promoteCandidate(
          value,
          host,
          guard,
          expectedWorking: saved,
        ),
      );
      failedHost.beforeFailure = () {
        records.beforeCommit = () async {
          records.beforeCommit = null;
          throw StateError('transient result write refusal');
        };
      };
      await candidate.verify(approved: true);
      final retained = candidate.history.single;
      expect(retained.finished, isTrue);
      expect(retained.snapshot.steps.last.operation, 'analyze');
      expect(retained.snapshot.steps.last.exitCode, 65);
      expect(retained.snapshot.steps.last.output, contains('Undefined name'));
      expect(candidate.result.steps.last.exitCode, 65);
      expect(candidateHost.operations, ['resolve', 'analyze']);
      expect(candidate.canPromote, isFalse);
      expect(workingHost.server, isTrue);
    },
  );

  test(
    'runtime signalling failure does not discard the durable Stop request',
    () async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      candidate.dispose();
      final host = FailingStopSignalHost();
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: host,
        publish: (_, _, _) => throw StateError('Unexpected promotion'),
      );
      host.stop = candidate.cancel;
      await candidate.verify(approved: true);
      expect(host.cancellations, greaterThanOrEqualTo(1));
      expect(candidate.stopRequestFor(candidate.history.single), isNotNull);
      expect(candidate.stopRequestSaveError, isNull);
      expect(candidate.error, isNot(contains('private runtime')));
      expect(candidate.history.single.snapshot.steps, isEmpty);
      expect(candidate.history.single.finished, isFalse);
    },
  );

  test(
    'late Stop retains actual successful exits and a separate request',
    () async {
      records.beforeCommit = () async {
        final journal = CandidateVerificationStore(records, project.id).load();
        if (journal.runs.isNotEmpty &&
            journal.runs.last.snapshot.steps.length == 4) {
          records.beforeCommit = null;
          candidate.cancel();
        }
      };
      await candidate.verify(approved: true);
      final run = candidate.history.single;
      expect(run.snapshot.steps.length, 4);
      expect(
        run.snapshot.steps.every(
          (step) => step.exitCode == 0 && !step.cancelled,
        ),
        isTrue,
      );
      expect(candidate.stopRequestFor(run), isNotNull);
      expect(candidate.stopRequestSaveError, isNull);
      expect(candidate.canPromote, isFalse);
      expect(candidate.savedExecutionFor(run)!.phase.name, 'verifying');
    },
  );

  test(
    'Stop save failure still signals immediately and retains unknown exits',
    () async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      final workingBefore = records.getString(
        'studio.generation.v1.${project.id}',
      );
      candidate.dispose();
      final host = InterruptedCheckHost();
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: host,
        publish: (_, _, _) => throw StateError('Unexpected promotion'),
      );
      host.stop = () {
        records.failCommit = true;
        candidate.cancel();
        expect(host.cancellations, 1);
        expect(candidate.stopRequestSaving, isTrue);
      };
      await candidate.verify(approved: true);
      records.failCommit = false;
      expect(candidate.stopRequestSaveError, contains('could not be saved'));
      expect(candidate.history.single.finished, isFalse);
      expect(candidate.history.single.snapshot.steps, isEmpty);
      expect(candidate.stopRequestFor(candidate.history.single), isNull);
      expect(
        records.getString('studio.generation.v1.${project.id}'),
        workingBefore,
      );
    },
  );

  test(
    'Stop during startup refuses dispatch without inventing a saved request',
    () async {
      final gate = Completer<void>();
      final entered = Completer<void>();
      records.beforeCommit = () async {
        records.beforeCommit = null;
        entered.complete();
        await gate.future;
      };
      final verification = candidate.verify(approved: true);
      await entered.future;
      candidate.cancel();
      expect(candidateHost.cancellations, 1);
      gate.complete();
      await verification;
      expect(candidateHost.verifications, 0);
      expect(candidate.history, isEmpty);
      expect(candidate.stopRequestSaveError, isNull);
      expect(
        records.values.keys.where(
          (key) => key.startsWith(CandidateVerificationStore.stopPrefix),
        ),
        isEmpty,
      );
    },
  );

  test(
    'Stop intent persists through disposal while its write is pending',
    () async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      candidate.dispose();
      final host = InterruptedCheckHost();
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: host,
        publish: (_, _, _) => throw StateError('Unexpected promotion'),
      );
      final gate = Completer<void>();
      final entered = Completer<void>();
      host.stop = () {
        records.beforeCommit = () async {
          records.beforeCommit = null;
          entered.complete();
          await gate.future;
        };
        candidate.cancel();
        expect(host.cancellations, 1);
        candidate.dispose();
      };
      var notifications = 0;
      candidate.addListener(() => notifications++);
      final verification = candidate.verify(approved: true);
      await entered.future;
      notifications = 0;
      gate.complete();
      await verification;
      expect(notifications, 0);
      final store = CandidateVerificationStore(records, project.id);
      final run = store.load().runs.single;
      expect(store.stopRequestFor(run), isNotNull);
      expect(run.finished, isFalse);
      expect(run.snapshot.pendingOperation, 'resolve');
      expect(run.snapshot.steps, isEmpty);
    },
  );

  testWidgets(
    'reopened history shows saved Stop separately without mutating journal',
    (tester) async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      candidate.dispose();
      final host = InterruptedCheckHost();
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: host,
        publish: (_, _, _) => throw StateError('Unexpected promotion'),
      );
      host.stop = candidate.cancel;
      await candidate.verify(approved: true);
      final run = candidate.history.single;
      final request = candidate.stopRequestFor(run)!;
      candidate.dispose();
      candidate = SourceCandidateController(
        project: project,
        candidate: run.snapshot,
        evidence: evidence,
        records: records,
        host: FixtureHost(),
        publish: (_, _, _) => throw StateError('Unexpected promotion'),
      );
      expect(
        candidate.stopRequestFor(candidate.history.single)!.toJson(),
        request.toJson(),
      );
      final before = Map.of(records.values);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SourceCandidateView(
                controller: candidate,
                actionsEnabled: false,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Saved candidate check runs'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.textContaining('Run 1:'));
      await tester.tap(find.textContaining('Run 1:'));
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Saved Stop request. This does not confirm command exit or cleanup.',
        ),
        findsOneWidget,
      );
      expect(records.values, before);
      expect(candidate.canPromote, isFalse);
      expect(candidate.history.single.snapshot.steps, isEmpty);
    },
  );

  test(
    'corrupt Stop evidence remains separate from valid interrupted history',
    () async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      candidate.dispose();
      final host = InterruptedCheckHost();
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: host,
        publish: (_, _, _) => throw StateError('Unexpected promotion'),
      );
      host.stop = candidate.cancel;
      await candidate.verify(approved: true);
      final run = candidate.history.single;
      final key = '${CandidateVerificationStore.stopPrefix}${run.dispatchId}';
      records.values[key] = '{private damaged stop evidence';
      candidate.dispose();
      candidate = SourceCandidateController(
        project: project,
        candidate: run.snapshot,
        evidence: evidence,
        records: records,
        host: FixtureHost(),
        publish: (_, _, _) => throw StateError('Unexpected promotion'),
      );
      expect(candidate.historyError, isNull);
      expect(candidate.stopRequestHistoryError, isNotNull);
      expect(
        candidate.stopRequestHistoryError,
        isNot(contains('private damaged')),
      );
      expect(candidate.stopRequestFor(candidate.history.single), isNull);
      expect(records.values[key], '{private damaged stop evidence');
      expect(candidate.history.single.finished, isFalse);
    },
  );

  test(
    'Stop preserves a pending command as interrupted in saved history',
    () async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      candidate.dispose();
      final host = InterruptedCheckHost();
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: host,
        publish: (value, host, guard) =>
            throw StateError('Unexpected publication'),
      );
      host.stop = candidate.cancel;

      await candidate.verify(approved: true);
      final retained = candidate.history.single;
      expect(retained.finished, isFalse);
      expect(retained.snapshot.pendingOperation, 'resolve');
      final before = Map<String, String>.of(records.values);
      expect(candidate.savedExecutionFor(retained)!.phase.name, 'executing');
      expect(records.values, before);
      expect(retained.snapshot.steps, isEmpty);
      expect(candidate.canPromote, isFalse);
    },
  );

  for (final complete in [false, true]) {
    testWidgets('saved execution visible without replay: completed=$complete', (
      tester,
    ) async {
      await candidate.verify(approved: true);
      if (complete) expect(await candidate.promote(approved: true), isTrue);
      final run = candidate.history.single;
      final before = Map<String, String>.of(records.values);
      final calls = candidateHost.verifications;
      final previous = candidate;
      candidate = SourceCandidateController(
        project: project,
        candidate: previous.result,
        evidence: previous.evidence,
        records: records,
        host: candidateHost,
        publish: (value, host, guard) => throw StateError('Unexpected replay'),
      );
      previous.dispose();
      final phase = complete ? 'completed' : 'verifying';
      expect(candidate.savedExecutionFor(run)!.phase.name, phase);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: SourceCandidateView(controller: candidate),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Saved candidate check runs'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Run 1: checks passed'));
      await tester.tap(find.text('Run 1: checks passed'));
      await tester.pumpAndSettle();
      expect(find.text('Saved dispatch: ${run.dispatchId}'), findsOneWidget);
      expect(find.textContaining('Saved execution: $phase'), findsOneWidget);
      expect(records.values, before);
      expect(candidateHost.verifications, calls);
    });
  }

  test('missing and corrupt execution evidence remains unavailable', () async {
    await candidate.verify(approved: true);
    final run = candidate.history.single;
    final key = 'studio.agentExecution.v1.${run.dispatchId!.split(':').first}';
    final legacy = CandidateVerificationRun.fromJson(
      Map<String, dynamic>.from(run.toJson())..remove('dispatchId'),
    );
    expect(candidate.savedExecutionFor(legacy), isNull);
    final saved = records.values.remove(key)!;
    expect(candidate.savedExecutionFor(run), isNull);
    records.values[key] = saved.replaceFirst('"taskId":"', '"taskId":"other-');
    expect(candidate.savedExecutionFor(run), isNull);
    records.values[key] = 'unreadable';
    expect(candidate.savedExecutionFor(run), isNull);
    expect(records.values[key], 'unreadable');
  });

  testWidgets(
    'interrupted receipts display separately without rewriting unknown exits',
    (tester) async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      candidate.dispose();
      final host = ReceiptCheckHost();
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: host,
        publish: (_, _, _) => throw StateError('Unexpected publication'),
      );
      host.stop = candidate.cancel;
      await candidate.verify(approved: true);
      await tester.pump();
      final run = candidate.history.single;
      expect(host.prepared!.dispatchId, run.dispatchId);
      expect(host.preparations, 1);
      expect(candidate.receiptsFor(run).single.result.exitCode, -1);
      expect(
        candidate.recoveryStatusFor(run)!.reason,
        CandidateRecoveryReason.retainedExit,
      );
      expect(candidate.recoveryStatusFor(run)!.exitCode, -1);
      expect(run.finished, isFalse);
      expect(run.snapshot.steps, isEmpty);
      expect(run.snapshot.pendingOperation, 'resolve');
      expect(candidate.canPromote, isFalse);
      final before = Map.of(records.values);
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child ?? const SizedBox(),
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SourceCandidateView(controller: candidate),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('Saved candidate check runs'));
      await tester.tap(find.text('Saved candidate check runs'));
      await tester.pumpAndSettle();
      final label = find.text('Run 1: interrupted or still active');
      await tester.ensureVisible(label);
      await tester.tap(label);
      await tester.pumpAndSettle();
      expect(
        find.text('Retained resolve result: exit -1 (cancelled)'),
        findsOneWidget,
      );
      expect(
        find.text('Cleanup remains unknown in this retained record.'),
        findsOneWidget,
      );
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              (widget.data?.startsWith(
                    'Recovery: The retained resolve exit is -1.',
                  ) ??
                  false),
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      expect(records.values, before);
      expect(candidate.canPromote, isFalse);
    },
  );

  test(
    'receipt preparation failure starts no check and preserves working output',
    () async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      final workingBefore = records.getString(
        'studio.generation.v1.${project.id}',
      );
      candidate.dispose();
      final host = ReceiptCheckHost()..failPreparation = true;
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: host,
        publish: (_, _, _) => throw StateError('Unexpected publication'),
      );
      await candidate.verify(approved: true);
      expect(host.prepared, isNull);
      expect(candidate.history.single.snapshot.pendingOperation, isEmpty);
      expect(candidate.receiptsFor(candidate.history.single), isEmpty);
      expect(
        records.getString('studio.generation.v1.${project.id}'),
        workingBefore,
      );
      expect(candidate.error, isNot(contains('private receipt path')));
    },
  );

  for (final close in [false, true]) {
    test(
      'pending receipt preparation honors ${close ? 'disposal' : 'Stop'} before commands',
      () async {
        final initial = candidate.result;
        final evidence = candidate.evidence;
        final workingBefore = records.getString(
          'studio.generation.v1.${project.id}',
        );
        candidate.dispose();
        final host = ReceiptCheckHost()..preparation = Completer<void>();
        candidate = SourceCandidateController(
          project: project,
          candidate: initial,
          evidence: evidence,
          records: records,
          host: host,
          publish: (_, _, _) => throw StateError('Unexpected publication'),
        );
        final verification = candidate.verify(approved: true);
        await tick();
        expect(host.preparations, 1);
        final before = Map.of(records.values);
        if (close) {
          candidate.dispose();
        } else {
          candidate.cancel();
        }
        host.preparation!.complete();
        await verification;
        expect(host.prepared, isNull);
        expect(
          records.getString('studio.generation.v1.${project.id}'),
          workingBefore,
        );
        if (close) {
          expect(records.values, before);
        } else {
          expect(candidate.history.single.snapshot.pendingOperation, isEmpty);
          expect(candidate.history.single.snapshot.steps, isEmpty);
        }
      },
    );
  }

  test(
    'recovery summary tracks async evidence without writing or stale input',
    () async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      candidate.dispose();
      final host = ReceiptCheckHost()
        ..deferred = Completer<List<CandidateOperationReceipt>>();
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: host,
        publish: (_, _, _) => throw StateError('Unexpected publication'),
      );
      host.stop = candidate.cancel;
      await candidate.verify(approved: true);
      final run = candidate.history.single;
      final before = Map.of(records.values);
      expect(
        candidate.recoveryStatusFor(run)!.reason,
        CandidateRecoveryReason.loading,
      );
      host.deferred!.complete([host.receipt(run)]);
      await tick();
      expect(
        candidate.recoveryStatusFor(run)!.reason,
        CandidateRecoveryReason.retainedExit,
      );
      final stale = CandidateVerificationRun(
        number: run.number,
        startedAt: run.startedAt,
        dispatchId: run.dispatchId,
        finished: run.finished,
        snapshot: GeneratedProject.fromJson({
          ...run.snapshot.toJson(),
          'directory': '/different',
        }),
      );
      expect(candidate.recoveryStatusFor(stale), isNull);
      expect(records.values, before);
      final journalKey = 'studio.candidateChecks.v1.${project.id}';
      records.values[journalKey] = 'unreadable history';
      await candidate.verify(approved: true);
      expect(candidate.historyError, isNotNull);
      expect(
        candidate.recoveryStatusFor(run)!.reason,
        CandidateRecoveryReason.evidenceUnavailable,
      );
      expect(candidate.recoveryStatusFor(run)!.exitCode, isNull);
      expect(records.values[journalKey], 'unreadable history');
    },
  );

  test('mismatched receipt reader cannot relabel another dispatch', () async {
    final initial = candidate.result;
    final evidence = candidate.evidence;
    candidate.dispose();
    final host = ReceiptCheckHost()..mismatch = true;
    candidate = SourceCandidateController(
      project: project,
      candidate: initial,
      evidence: evidence,
      records: records,
      host: host,
      publish: (_, _, _) => throw StateError('Unexpected publication'),
    );
    host.stop = candidate.cancel;
    await candidate.verify(approved: true);
    final before = Map.of(records.values);
    await tick();
    expect(candidate.receiptHistoryError, isNotNull);
    expect(candidate.receiptsFor(candidate.history.single), isEmpty);
    expect(candidate.history.single.finished, isFalse);
    expect(records.values, before);
  });

  test('receipt read errors preserve journal and late reads cannot notify disposed controller', () async {
    final initial = candidate.result;
    final evidence = candidate.evidence;
    candidate.dispose();
    final host = ReceiptCheckHost()..failRead = true;
    candidate = SourceCandidateController(
      project: project,
      candidate: initial,
      evidence: evidence,
      records: records,
      host: host,
      publish: (_, _, _) => throw StateError('Unexpected publication'),
    );
    host.stop = candidate.cancel;
    await candidate.verify(approved: true);
    await tick();
    expect(candidate.receiptHistoryError, isNotNull);
    expect(
      candidate.receiptHistoryError,
      isNot(contains('private receipt path')),
    );
    final before = Map.of(records.values);
    final run = candidate.history.single;
    candidate.dispose();
    host.failRead = false;
    host.deferred = Completer<List<CandidateOperationReceipt>>();
    candidate = SourceCandidateController(
      project: project,
      candidate: run.snapshot,
      evidence: evidence,
      records: records,
      host: host,
      publish: (_, _, _) => throw StateError('Unexpected publication'),
    );
    var notifications = 0;
    candidate.addListener(() => notifications++);
    candidate.dispose();
    host.deferred!.complete([host.receipt(run)]);
    await tick();
    expect(notifications, 0);
    expect(records.values, before);
  });

  for (final state in ['retained', 'missing', 'unavailable']) {
    testWidgets(
      'recovery dialog describes $state evidence and dismissal at narrow2x',
      (tester) async {
        final initial = candidate.result;
        final evidence = candidate.evidence;
        candidate.dispose();
        final host = ReceiptCheckHost();
        if (state == 'missing') {
          host.deferred = Completer<List<CandidateOperationReceipt>>()
            ..complete([]);
        }
        if (state == 'unavailable') host.failRead = true;
        candidate = SourceCandidateController(
          project: project,
          candidate: initial,
          evidence: evidence,
          records: records,
          host: host,
          publish: (_, _, _) => throw StateError('Unexpected publication'),
        );
        host.stop = candidate.cancel;
        await candidate.verify(approved: true);
        await tester.pump();
        final before = Map.of(records.values);
        tester.view.physicalSize = const Size(320, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child ?? const SizedBox(),
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                child: SourceCandidateView(controller: candidate),
              ),
            ),
          ),
        );
        final resolve = find.widgetWithText(
          TextButton,
          'Resolve interrupted verification',
        );
        await tester.ensureVisible(resolve);
        await tester.tap(resolve);
        await tester.pumpAndSettle();
        final dialog = find.byType(AlertDialog);
        final description = tester
            .widget<Text>(
              find.descendant(
                of: dialog,
                matching: find.byWidgetPredicate(
                  (widget) =>
                      widget is Text &&
                      (widget.data?.startsWith(
                            'Check that the previous resolve',
                          ) ??
                          false),
                ),
              ),
            )
            .data!;
        expect(description, contains('inspect any candidate changes'));
        expect(description, contains('Confirm only after checking'));
        if (state == 'retained') {
          expect(description, contains('retained resolve exit is -1'));
          expect(description, contains('cleanup remain unknown'));
          expect(description, isNot(contains('Its exit outcome is unknown')));
        } else if (state == 'missing') {
          expect(
            description,
            contains('No actual exit was retained for resolve'),
          );
        } else {
          expect(description, contains('completion evidence is unavailable'));
        }
        expect(description, contains('Stop request is saved'));
        expect(tester.takeException(), isNull);
        await tester.ensureVisible(find.text('Keep interrupted'));
        await tester.tap(find.text('Keep interrupted'));
        await tester.pumpAndSettle();
        expect(records.values, before);
        expect(candidate.history.single.finished, isFalse);
        expect(candidate.canPromote, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'recovery dialog preserves dismissal and requires fresh consent',
    (tester) async {
      final initial = candidate.result;
      final evidence = candidate.evidence;
      candidate.dispose();
      final host = InterruptedCheckHost();
      candidate = SourceCandidateController(
        project: project,
        candidate: initial,
        evidence: evidence,
        records: records,
        host: host,
        publish: (value, host, guard) =>
            throw StateError('Unexpected publication'),
      );
      host.stop = candidate.cancel;
      await candidate.verify(approved: true);
      final before = candidate.history.single.toJson();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ListenableBuilder(
                listenable: candidate,
                builder: (_, _) => SourceCandidateView(controller: candidate),
              ),
            ),
          ),
        ),
      );
      final resolve = find.widgetWithText(
        TextButton,
        'Resolve interrupted verification',
      );
      await tester.ensureVisible(resolve);
      await tester.tap(resolve);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Keep interrupted'));
      await tester.pumpAndSettle();
      expect(candidate.history.single.toJson(), before);
      final checkbox = find.byType(CheckboxListTile).first;
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
      await tester.ensureVisible(resolve);
      await tester.tap(resolve);
      await tester.pumpAndSettle();
      await tester.tap(find.text('I checked the process and changes'));
      await tester.pumpAndSettle();
      expect(candidate.history.single.finished, isTrue);
      expect(candidate.history.single.snapshot.steps, isEmpty);
      final verify = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Verify candidate in sandbox'),
      );
      expect(verify.onPressed, isNull);
    },
  );

  testWidgets('stale recovery dialog preserves changed saved evidence', (
    tester,
  ) async {
    final initial = candidate.result;
    final evidence = candidate.evidence;
    candidate.dispose();
    final host = InterruptedCheckHost();
    candidate = SourceCandidateController(
      project: project,
      candidate: initial,
      evidence: evidence,
      records: records,
      host: host,
      publish: (value, host, guard) =>
          throw StateError('Unexpected publication'),
    );
    host.stop = candidate.cancel;
    await candidate.verify(approved: true);
    final before = candidate.history.single.toJson();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ListenableBuilder(
              listenable: candidate,
              builder: (_, _) => SourceCandidateView(controller: candidate),
            ),
          ),
        ),
      ),
    );
    final resolve = find.widgetWithText(
      TextButton,
      'Resolve interrupted verification',
    );
    await tester.ensureVisible(resolve);
    await tester.tap(resolve);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Keep interrupted'));
    await tester.pumpAndSettle();
    expect(candidate.history.single.toJson(), before);
    final checkbox = find.byType(CheckboxListTile).first;
    await tester.ensureVisible(checkbox);
    await tester.tap(checkbox);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
    await tester.ensureVisible(resolve);
    await tester.tap(resolve);
    await tester.pumpAndSettle();
    final key = 'studio.candidateChecks.v1.${project.id}';
    final changed = jsonDecode(records.getString(key)!) as Map<String, dynamic>;
    (changed['runs'] as List).last['startedAt'] = '2026-11-17T00:00:00.000Z';
    final replacement = jsonEncode(changed);
    records.values[key] = replacement;
    await tester.tap(find.text('I checked the process and changes'));
    await tester.pumpAndSettle();
    expect(candidate.history.single.finished, isFalse);
    expect(records.getString(key), replacement);
    expect(candidate.error, contains('Recovery could not be saved'));
    expect(candidate.history.single.snapshot.steps, isEmpty);
    final verify = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Verify candidate in sandbox'),
    );
    expect(verify.onPressed, isNull);
  });

  test('retries preserve actual results in separate saved runs', () async {
    candidateHost.throwAnalyze = true;
    await candidate.verify(approved: true);
    final first = candidate.history.single.snapshot.toJson();
    expect(candidate.history.single.finished, isTrue);
    candidateHost.throwAnalyze = false;
    await candidate.verify(approved: true);
    expect(candidate.history.length, 2);
    expect(candidate.history.first.snapshot.toJson(), first);
    expect(candidate.history.last.status, 'checks passed');
    expect(candidate.history.last.number, 2);
    expect(workingHost.server, isTrue);
  });

  test(
    'corrupt journal blocks host entry without replacing evidence',
    () async {
      final key = 'studio.candidateChecks.v1.${project.id}';
      records.values[key] = '{broken';
      await candidate.verify(approved: true);
      expect(candidateHost.verifications, 0);
      expect(records.values[key], '{broken');
      expect(candidate.historyError, contains('unreadable'));
      expect(workingHost.server, isTrue);
    },
  );

  test(
    'approval withdrawal during verification rejects later commands',
    () async {
      candidateHost.afterResolve = () async => PlanApprovalStore(records)
          .save(project, ConversationStore(records).load(project.id), false);
      await candidate.verify(approved: true);
      expect(candidateHost.operations, ['resolve']);
      expect(candidate.error, contains('stopped'));
      expect(workingHost.server, isTrue);
    },
  );

  test('preview failure and atomic save failure retain old pointer and live server', () async {
    await candidate.verify(approved: true);
    final old = records.getString('studio.generation.v1.${project.id}');
    candidateHost.previewGate = Completer<Uri>()
      ..completeError(StateError('preview unavailable'));
    expect(await candidate.promote(approved: true), isFalse);
    expect(workingHost.server, isTrue);
    candidateHost.previewGate = null;
    records.failCommit = true;
    final executionKey =
        'studio.agentExecution.v1.${candidate.history.last.dispatchId!.split(':').first}';
    final executionBefore = records.getString(executionKey);
    expect(await candidate.promote(approved: true), isFalse);
    expect(records.getString(executionKey), executionBefore);
    expect(jsonDecode(executionBefore!)['phase'], 'verifying');
    expect(candidateHost.server, isFalse);
    expect(workingHost.server, isTrue);
    expect(records.getString('studio.generation.v1.${project.id}'), old);
    expect(working.result!.directory, '/working');
  });

  test(
    'concurrent approval/build changes at commit refuse without overwriting',
    () async {
      await candidate.verify(approved: true);
      records.beforeCommit = () async {
        await PlanApprovalStore(records)
            .save(project, ConversationStore(records).load(project.id), false);
      };
      expect(await candidate.promote(approved: true), isFalse);
      expect(workingHost.server, isTrue);
      expect(
        SourceGenerationStore(records).load(project.id)!.directory,
        '/working',
      );
      expect(candidateHost.server, isFalse);
    },
  );

  test(
    'checkpoint write failure never executes and disposal stops owned host',
    () async {
      records.failCommit = true;
      await candidate.verify(approved: true);
      expect(candidateHost.operations, isEmpty);
      expect(candidate.canPromote, isFalse);
      expect(workingHost.server, isTrue);
      candidate.dispose();
      expect(candidateHost.disposed, isTrue);
      expect(
        jsonDecode(
          records.getString('studio.generation.v1.${project.id}')!,
        )['directory'],
        '/working',
      );
    },
  );
  test('working build changed since review cannot be replaced', () async {
    await candidate.verify(approved: true);
    await SourceGenerationStore(records)
        .save(project.id, saved.copy(error: 'changed working record'));
    expect(await candidate.promote(approved: true), isFalse);
    expect(workingHost.server, isTrue);
    expect(candidateHost.server, isFalse);
  });

  testWidgets('narrow enlarged candidate consent and explicit promotion flow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: ListenableBuilder(
            listenable: candidate,
            builder: (_, _) => ListView(
              padding: const EdgeInsets.all(16),
              children: [SourceCandidateView(controller: candidate)],
            ),
          ),
        ),
      ),
    );
    Future<void> tapText(String text) async {
      await tester.scrollUntilVisible(
        find.text(text),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text(text));
      await tester.pumpAndSettle();
      await tester.tap(find.text(text));
      await tester.pumpAndSettle();
    }

    await tapText('I approve confined candidate verification');
    await tapText('Verify candidate in sandbox');
    expect(candidate.result.phase, SourceGenerationPhase.ready);
    expect(working.result!.directory, '/working');
    await tapText('Promote verified candidate and refresh preview');
    expect(candidate.promoted, isTrue);
    expect(working.result!.directory, '/candidate');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  test('confinement marker survives roundtrip and rejects unsupported types/versions', () {
    final raw = candidate.result.toJson();
    expect(GeneratedProject.fromJson(raw).confined, isTrue);
    for (final bad in [null, true, 1.0, '1', 2]) {
      expect(
        () => GeneratedProject.fromJson({...raw, 'confinementVersion': bad}),
        throwsFormatException,
      );
    }
  });
  test('publication refuses reuse of the live working preview host', () async {
    await candidate.verify(approved: true);
    await expectLater(
      working.promoteCandidate(
        candidate.result,
        workingHost,
        () {},
        expectedWorking: saved,
      ),
      throwsStateError,
    );
    expect(workingHost.server, isTrue);
    expect(working.result!.directory, '/working');
  });
}
