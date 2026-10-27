import 'dart:convert';

import 'package:asg/controllers/requirement_check_report_controller.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/build_task.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/requirement_check_report.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/requirement_check_report_screen.dart';
import 'package:asg/views/project_workspace.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'board_mapped_build_plan_test.dart'
    show sharedBoard, sharedContract, boardContent, mappedBoard;

class Records implements RecordStorage {
  final data = <String, String>{};
  @override
  String? getString(String key) => data[key];
  @override
  Future<bool> setString(String key, String value) async {
    data[key] = value;
    return true;
  }
}

const project = StudioProject(
  id: 'p',
  name: 'Report',
  description: 'Task app',
  type: 'Flutter',
  platforms: ['Web'],
  location: 'PRIVATE_LOCATION',
);

Future<GeneratedProject> prepare(
  Records records, {
  RequirementsBoard? board,
  String? content,
}) async {
  await StudioStore(records).save([project]);
  final requirementStore = RequirementsStore(records);
  final savedBoard = await requirementStore.save(
    'p',
    RequirementsBoard(),
    board ?? sharedBoard(done: true),
  );
  final approvals = PlanApprovalStore(records);
  final plan = content ?? boardContent(sharedContract());
  final messages = [
    ChatMessage(
      role: 'assistant',
      content: plan,
      planContext: approvals.contextFor(project),
    ),
  ];
  await ConversationStore(records).save('p', messages);
  await approvals.save(project, messages, true);
  final tasks = BuildPlan.parse(plan, board: savedBoard).tasks;
  return GeneratedProject(
    directory: 'PRIVATE_DIRECTORY',
    sdk: 'PRIVATE_SDK',
    python: 'python3',
    sources: GenerationInput(
      project,
      ApplicationStore(records).load(project).definition,
    ).fingerprints,
    tasks: tasks,
    approval: approvals.load('p'),
    phase: SourceGenerationPhase.ready,
    steps: [
      for (final t in tasks)
        GenerationStep(
          operation: t.operation.name,
          exitCode: 0,
          output: 'PRIVATE_RAW_OUTPUT',
        ),
    ],
    outputs: {'index.html': 'a' * 64, 'main.dart.js': 'b' * 64},
  );
}

void main() {
  test('copied context reconstructs exact criteria and task graph with canonical digest', () async {
    final records = Records();
    final base = mappedBoard();
    final board = RequirementsBoard(
      requirements: const [
        ProjectRequirement(
          id: 'R1',
          title: 'Task "board" 🧪',
          acceptance: 'Keep exact spaces  \nand Unicode ✓',
        ),
      ],
      tasks: [
        for (final task in base.tasks)
          DevelopmentTask(
            id: task.id,
            requirementId: task.requirementId,
            title: '${task.title} ✓',
            dependencies: task.dependencies,
            status: TaskStatus.done,
          ),
      ],
    );
    final saved = await prepare(records, board: board, content: boardContent());
    await SourceGenerationStore(records).save('p', saved);
    final before = Map.of(records.data);
    final report = RequirementCheckReportStore(records).load(project);
    final evidence = jsonDecode(report.evidenceJson) as Map<String, dynamic>;
    final copiedBoard = RequirementsBoard.fromJson(
      evidence['requirementsBoard'] as Map<String, dynamic>,
    );
    final original = RequirementsStore(records).load('p');
    expect(copiedBoard.toJson(), original.toJson());
    expect(
      copiedBoard.requirements.single.acceptance,
      board.requirements.single.acceptance,
    );
    expect(copiedBoard.tasks.last.dependencies, isNotEmpty);
    expect(
      copiedBoard.tasks.every((task) => task.status == TaskStatus.done),
      isTrue,
    );
    expect(
      evidence['requirementsBoardSha256'],
      sha256.convert(utf8.encode(jsonEncode(copiedBoard.toJson()))).toString(),
    );
    expect(evidence['requirementsRevision'], copiedBoard.revision);
    expect(
      (evidence['requirements'] as List).single['acceptanceStatus'],
      'unverified',
    );
    expect(report.evidenceJson, isNot(contains('PRIVATE_')));
    expect(records.data, before);
    final reopened = Records()..data.addAll(before);
    expect(
      RequirementCheckReportStore(reopened).load(project).evidenceJson,
      report.evidenceJson,
    );
  });

  test('board digest binds criteria and task content even at an equal imported revision', () async {
    final records = Records();
    final saved = await prepare(records);
    await SourceGenerationStore(records).save('p', saved);
    final store = RequirementCheckReportStore(records);
    final original = jsonDecode(
      records.data[RequirementsStore.key('p')]!,
    ) as Map<String, dynamic>;
    final first = jsonDecode(store.load(project).evidenceJson) as Map;
    for (final field in ['title', 'acceptance', 'taskTitle', 'status']) {
      final changed = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
      if (field == 'taskTitle') {
        (changed['tasks'] as List).first['title'] = 'Changed task';
      } else if (field == 'status') {
        (changed['tasks'] as List).first['status'] = 'queued';
      } else {
        (changed['requirements'] as List).first[field] = 'Changed criterion';
      }
      records.data[RequirementsStore.key('p')] = jsonEncode(changed);
      final next = jsonDecode(store.load(project).evidenceJson) as Map;
      expect(next['requirementsRevision'], first['requirementsRevision']);
      expect(
        next['requirementsBoardSha256'],
        isNot(first['requirementsBoardSha256']),
        reason: field,
      );
    }
  });

  test(
    'missing board and saved empty board remain distinct without generation',
    () async {
      final records = Records();
      final store = RequirementCheckReportStore(records);
      final missing = jsonDecode(store.load(project).evidenceJson) as Map;
      expect(missing['requirementsRevision'], 0);
      expect(missing['requirementsBoard'], isNull);
      expect(missing['requirementsBoardSha256'], isNull);
      await RequirementsStore(records)
          .save('p', RequirementsBoard(), RequirementsBoard());
      final empty =
          jsonDecode(store.load(project).evidenceJson) as Map<String, dynamic>;
      expect(
        RequirementsBoard.fromJson(
          empty['requirementsBoard'] as Map<String, dynamic>,
        ).requirements,
        isEmpty,
      );
      expect(
        empty['requirementsBoardSha256'],
        matches(RegExp(r'^[0-9a-f]{64}$')),
      );
      expect(empty['phase'], isNull);
      final board = RequirementsStore(records).load('p');
      await RequirementsStore(records).save('p', board, sharedBoard());
      final report = store.load(project);
      expect(report.results.single.state, RequirementCheckState.missing);
      expect(
        (jsonDecode(
          report.evidenceJson,
        ) as Map)['requirementsBoard']['requirements'].single['acceptance'],
        'Verify output',
      );
    },
  );

  testWidgets(
    'expanded copied evidence declares authored content at narrow enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = Records();
      await prepare(records);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: RequirementCheckReportScreen(
            controller: RequirementCheckReportController(
              project,
              RequirementCheckReportStore(records),
            ),
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Exact saved revision and results'),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await tester.drag(find.byType(ListView), const Offset(0, -250));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Exact saved revision and results'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(RequirementCheckReport.authoredEvidenceNotice),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(
        find.text(RequirementCheckReport.authoredEvidenceNotice),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              (widget.data?.contains('requirementsBoardSha256') ?? false),
        ),
        200,
        scrollable: find
            .descendant(
              of: find.byType(ListView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      final selectable = tester.widget<SelectableText>(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectableText &&
              (widget.data?.contains('requirementsBoardSha256') ?? false),
        ),
      );
      final copied = jsonDecode(selectable.data!) as Map;
      expect(
        copied['savedEvidence']['requirementsBoard']['requirements']
            .single['acceptance'],
        'Verify output',
      );
      expect(copied['artifactInspection'], isNull);
      expect(tester.takeException(), isNull);
    },
  );

  test('durable mapped report links exact evidence without writes or raw diagnostics', () async {
    final records = Records();
    final saved = await prepare(records);
    await SourceGenerationStore(records).save('p', saved);
    final before = Map.of(records.data);
    final report = RequirementCheckReportStore(records).load(project);
    expect(
      report.results.single.state,
      RequirementCheckState.mappedChecksPassed,
    );
    expect(report.results.single.taskIds, ['Tstarter']);
    expect(report.results.single.operationIds, saved.tasks!.map((t) => t.id));
    final json = jsonDecode(report.evidenceJson) as Map;
    expect(json['requirementsRevision'], 1);
    expect(json['sourceFingerprints'], saved.sources);
    expect(json['outputFingerprints'], saved.outputs);
    expect(json['recordedAt'], isNotNull);
    expect(json['approvalFingerprint'], matches(RegExp(r'^[0-9a-f]{64}$')));
    expect(
      (json['results'] as List).map((r) => r['exitCode']),
      everyElement(0),
    );
    for (final private in [
      'PRIVATE_LOCATION',
      'PRIVATE_DIRECTORY',
      'PRIVATE_SDK',
      'PRIVATE_RAW_OUTPUT',
    ]) {
      expect(report.evidenceJson, isNot(contains(private)));
    }
    expect(records.data, before);
    final reopened = Records()..data.addAll(records.data);
    expect(
      RequirementCheckReportStore(reopened).load(project).evidenceJson,
      report.evidenceJson,
    );
    expect(() => report.results.clear(), throwsUnsupportedError);
    expect(() => report.results.single.taskIds.clear(), throwsUnsupportedError);
  });
  test(
    'missing and unmapped manual Done tasks never count as checks',
    () async {
      final records = Records();
      final board = sharedBoard(done: true);
      final saved = await prepare(
        records,
        board: RequirementsBoard(
          requirements: [
            ...board.requirements,
            const ProjectRequirement(
              id: 'R2',
              title: 'Unmapped',
              acceptance: 'Needs tests',
            ),
          ],
          tasks: [
            ...board.tasks,
            DevelopmentTask(
              id: 'Textra',
              requirementId: 'R1',
              title: 'Manual',
              status: TaskStatus.done,
            ),
          ],
        ),
      );
      final store = RequirementCheckReportStore(records);
      expect(
        store
            .load(project)
            .results
            .every((r) => r.state == RequirementCheckState.missing),
        isTrue,
      );
      await SourceGenerationStore(records).save('p', saved);
      expect(
        store
            .load(project)
            .results
            .every((r) => r.state == RequirementCheckState.missing),
        isTrue,
      );
      final legacy = Records();
      final unmapped = await prepare(
        legacy,
        content: BuildPlan.starterContract,
      );
      await SourceGenerationStore(legacy).save('p', unmapped);
      expect(
        RequirementCheckReportStore(legacy).load(project).results.single.state,
        RequirementCheckState.missing,
      );
    },
  );
  test('failure, timeout, cancellation, output exhaustion and partial runs cannot pass', () async {
    final records = Records();
    final saved = await prepare(records);
    final store = SourceGenerationStore(records);
    for (final step in [
      GenerationStep(
        operation: saved.tasks!.first.operation.name,
        exitCode: 1,
        output: 'failed',
      ),
      GenerationStep(
        operation: saved.tasks!.first.operation.name,
        exitCode: 0,
        output: '',
        timedOut: true,
      ),
      GenerationStep(
        operation: saved.tasks!.first.operation.name,
        exitCode: 0,
        output: '',
        cancelled: true,
      ),
      GenerationStep(
        operation: saved.tasks!.first.operation.name,
        exitCode: 0,
        output: '',
        outputLimitExceeded: true,
      ),
    ]) {
      await store.save(
        'p',
        saved.copy(phase: SourceGenerationPhase.failed, steps: [step]),
      );
      expect(
        RequirementCheckReportStore(records).load(project).results.single.state,
        RequirementCheckState.failed,
      );
    }
    await store.save(
      'p',
      saved.copy(
        phase: SourceGenerationPhase.verifying,
        steps: saved.steps.take(2).toList(),
      ),
    );
    expect(
      RequirementCheckReportStore(records).load(project).results.single.state,
      RequirementCheckState.incomplete,
    );
    await store.save(
      'p',
      saved.copy(phase: SourceGenerationPhase.generated, steps: []),
    );
    expect(
      RequirementCheckReportStore(records).load(project).results.single.state,
      RequirementCheckState.incomplete,
    );
  });
  test('board, prototype, approval and source-input changes make old successes stale', () async {
    for (final change in [
      'board',
      'prototype',
      'withdraw',
      'reapprove',
      'sources',
      'graph',
      'newPlan',
    ]) {
      final records = Records();
      var saved = await prepare(records);
      await SourceGenerationStore(records).save('p', saved);
      switch (change) {
        case 'board':
          final store = RequirementsStore(records);
          await store.save('p', store.load('p'), sharedBoard());
        case 'prototype':
          final store = ApplicationStore(records);
          final app = store.load(project);
          await store.save(
            'p',
            ApplicationSnapshot(app.definition, app.messages, app.revision + 1),
          );
        case 'withdraw':
          await PlanApprovalStore(records)
              .save(project, ConversationStore(records).load('p'), false);
        case 'reapprove':
          final raw = jsonDecode(
            records.data['studio.planApproval.v1.p']!,
          ) as Map<String, dynamic>;
          raw['recordedAt'] = '2027-01-01T00:00:00Z';
          records.data['studio.planApproval.v1.p'] = jsonEncode(raw);
        case 'sources':
          saved = GeneratedProject(
            directory: saved.directory,
            sdk: saved.sdk,
            python: saved.python,
            sources: {'lib/main.dart': 'c' * 64},
            tasks: saved.tasks,
            approval: saved.approval,
            steps: saved.steps,
            outputs: saved.outputs,
            phase: saved.phase,
          );
          await SourceGenerationStore(records).save('p', saved);
        case 'graph':
          await SourceGenerationStore(records).save(
            'p',
            saved.copy(
              tasks: BuildTask.fromJson([
                for (final t in saved.tasks!) t.toJson()..remove('boardTaskId'),
              ]),
            ),
          );
        case 'newPlan':
          final messages = ConversationStore(records).load('p');
          await ConversationStore(records).save('p', [
            ...messages,
            ChatMessage(
              role: 'assistant',
              content: 'Another Plan',
              planContext: messages.single.planContext,
            ),
          ]);
      }
      expect(
        RequirementCheckReportStore(records).load(project).results.single.state,
        RequirementCheckState.stale,
        reason: change,
      );
    }
  });
  test('controller clears stale screen success on corrupt evidence and supports reload/dispose', () async {
    final records = Records();
    final saved = await prepare(records);
    await SourceGenerationStore(records).save('p', saved);
    final good = Map.of(records.data);
    final controller = RequirementCheckReportController(
      project,
      RequirementCheckReportStore(records),
    );
    for (final key in [
      'studio.generation.v1.p',
      'studio.requirements.v1.p',
      'studio.application.v1.p',
    ]) {
      records.data
        ..clear()
        ..addAll(good);
      controller.load();
      expect(controller.report, isNotNull);
      records.data[key] = 'PRIVATE_CORRUPT';
      final before = Map.of(records.data);
      controller.load();
      expect(controller.report, isNull);
      expect(controller.error, isNot(contains('PRIVATE_CORRUPT')));
      expect(records.data, before);
    }
    records.data
      ..clear()
      ..addAll(good);
    controller.load();
    expect(controller.error, isNull);
    controller.dispose();
    records.data.clear();
    controller.load();
    expect(controller.report, isNotNull);
  });
  test('requirement evidence is scoped, immutable and survives reopen without writes', () async {
    final records = Records();
    final original = mappedBoard();
    final saved = await prepare(
      records,
      content: boardContent(),
      board: RequirementsBoard(
        requirements: [
          ...original.requirements,
          const ProjectRequirement(
            id: 'R2',
            title: 'Output',
            acceptance: 'Show result',
          ),
        ],
        tasks: [
          for (final task in original.tasks)
            DevelopmentTask(
              id: task.id,
              requirementId: task.id == 'Tbuild' ? 'R2' : 'R1',
              title: task.title,
              dependencies: task.dependencies,
            ),
        ],
      ),
    );
    await SourceGenerationStore(records).save('p', saved);
    final before = Map.of(records.data);
    final report = RequirementCheckReportStore(records).load(project);
    expect(report.results.first.checks.map((c) => c.operation), [
      BuildOperation.resolve,
      BuildOperation.test,
      BuildOperation.analyze,
    ]);
    expect(report.results.last.checks.single.operation, BuildOperation.build);
    expect(report.results.last.checks.single.boardTaskId, 'Tbuild');
    expect(report.results.last.checks.single.exitCode, 0);
    expect(report.results.last.requirement.acceptance, 'Show result');
    final json = jsonDecode(report.evidenceJson) as Map;
    expect(
      (json['requirements'] as List).map((r) => r['acceptanceStatus']),
      everyElement('unverified'),
    );
    expect(() => report.results.first.checks.clear(), throwsUnsupportedError);
    final reopened = Records()..data.addAll(before);
    expect(
      RequirementCheckReportStore(reopened).load(project).evidenceJson,
      report.evidenceJson,
    );
    expect(records.data, before);
    expect(report.evidenceJson, isNot(contains('PRIVATE_')));
  });
  test(
    'scoped checks retain actual failure flags and absent results',
    () async {
      final records = Records();
      final saved = await prepare(records);
      for (final failure in [
        const GenerationStep(
          operation: 'resolve',
          exitCode: 9,
          output: 'PRIVATE_LOG',
        ),
        const GenerationStep(
          operation: 'resolve',
          exitCode: 0,
          output: 'PRIVATE_LOG',
          timedOut: true,
        ),
        const GenerationStep(
          operation: 'resolve',
          exitCode: 0,
          output: 'PRIVATE_LOG',
          cancelled: true,
        ),
        const GenerationStep(
          operation: 'resolve',
          exitCode: 0,
          output: 'PRIVATE_LOG',
          outputLimitExceeded: true,
        ),
      ]) {
        await SourceGenerationStore(records).save(
          'p',
          saved.copy(phase: SourceGenerationPhase.failed, steps: [failure]),
        );
        final result = RequirementCheckReportStore(records)
            .load(project)
            .results
            .single;
        final check = result.checks.first;
        expect(result.state, RequirementCheckState.failed);
        expect(check.status, BuildTaskStatus.failed);
        expect(check.exitCode, failure.exitCode);
        expect(check.timedOut, failure.timedOut);
        expect(check.cancelled, failure.cancelled);
        expect(check.outputLimitExceeded, failure.outputLimitExceeded);
        expect(result.checks.last.exitCode, isNull);
        expect(result.checks.last.summary, 'No saved command result');
        expect(result.checks.last.status, BuildTaskStatus.blocked);
        expect(check.summary, isNot(contains('PRIVATE_LOG')));
      }
    },
  );
  testWidgets(
    'acceptance and scoped outcomes stay visible after durable reload',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = Records();
      final saved = await prepare(records);
      await SourceGenerationStore(records).save(
        'p',
        saved.copy(
          phase: SourceGenerationPhase.failed,
          steps: [
            const GenerationStep(
              operation: 'resolve',
              exitCode: 7,
              output: 'PRIVATE_LOG',
              timedOut: true,
            ),
          ],
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: RequirementCheckReportScreen(
            controller: RequirementCheckReportController(
              project,
              RequirementCheckReportStore(records),
            ),
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.text(RequirementCheckResult.acceptanceStatus),
        200,
      );
      expect(find.text('Verify output'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.textContaining('Exit 7; timed out: true'),
        200,
      );
      expect(find.textContaining('PRIVATE_LOG'), findsNothing);
      expect(tester.takeException(), isNull);
      final store = RequirementsStore(records);
      final board = store.load('p');
      await store.save(
        'p',
        board,
        RequirementsBoard(
          requirements: const [
            ProjectRequirement(
              id: 'R1',
              title: 'Starter',
              acceptance: 'Changed acceptance',
            ),
          ],
          tasks: board.tasks,
        ),
      );
      await tester.scrollUntilVisible(find.text('Reload saved evidence'), -200);
      await tester.tap(find.text('Reload saved evidence'));
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Changed acceptance'), 200);
      await tester.scrollUntilVisible(find.text('Stale evidence'), 200);
      expect(find.text('Verify output'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'workspace opens deterministic report from requirements and returns safely',
    (tester) async {
      final records = Records();
      final saved = await prepare(records);
      await SourceGenerationStore(records).save('p', saved);
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectWorkspace(project: project, records: records),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Requirements and tasks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Requirement check report'));
      await tester.pumpAndSettle();
      expect(find.byType(RequirementCheckReportScreen), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Mapped checks passed'), 150);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.text('Requirements and tasks'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(find.byType(ProjectWorkspace), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'report is readable at narrow enlarged text and reloads saved evidence',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = Records();
      final saved = await prepare(records);
      await SourceGenerationStore(records).save('p', saved);
      final controller = RequirementCheckReportController(
        project,
        RequirementCheckReportStore(records),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: RequirementCheckReportScreen(controller: controller),
        ),
      );
      await tester.scrollUntilVisible(find.text('Mapped checks passed'), 200);
      expect(tester.takeException(), isNull);
      await PlanApprovalStore(records)
          .save(project, ConversationStore(records).load('p'), false);
      await tester.scrollUntilVisible(find.text('Reload saved evidence'), -200);
      await tester.tap(find.text('Reload saved evidence'));
      await tester.pump();
      await tester.scrollUntilVisible(find.text('Stale evidence'), 200);
      expect(tester.takeException(), isNull);
    },
  );
}
