import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/source_candidate_controller.dart';
import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/generation_input.dart';
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
      records.failWrite = records.writes + 1;
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
