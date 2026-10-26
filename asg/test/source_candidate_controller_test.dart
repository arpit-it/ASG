import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/source_candidate_controller.dart';
import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/candidate_failure.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/application_store.dart';
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

  test(
    'separate consent, candidate evidence, atomic promotion and host ownership',
    () async {
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
      expect(await candidate.promote(approved: true), isTrue);
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
    },
  );

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
    expect(await candidate.promote(approved: true), isFalse);
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
