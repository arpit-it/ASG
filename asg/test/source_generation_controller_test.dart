import 'dart:async';
import 'dart:convert';

import 'package:asg/services/folder_picker.dart';

import 'board_mapped_build_plan_test.dart'
    show mappedBoard, boardContent, boardContract, sharedBoard, sharedContract;

import 'package:asg/models/requirements_board.dart';

import 'package:asg/models/build_plan.dart';

import 'package:asg/models/build_task.dart';

import 'package:asg/models/chat_message.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/artifact_inspection.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/generation_host.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/views/source_generation_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const project = StudioProject(
  id: 'p',
  name: 'App',
  description: '',
  type: 'Flutter',
  platforms: ['Web'],
  location: '',
);
const definition = AppDefinition(
  title: 'App',
  theme: 'green',
  elements: [
    AppElement(id: 'heading', kind: ElementKind.heading, label: 'Welcome'),
  ],
);
final generated = GeneratedProject(
  directory: '/generated',
  sdk: '/sdk',
  python: 'python3',
  sources: {
    ...GenerationInput(project, definition).fingerprints,
    'lib/main.dart':
        '0000000000000000000000000000000000000000000000000000000000000000',
  },
);

class FixtureHost implements GenerationHost, ArtifactInspector {
  Completer<ArtifactInspection>? inspectionGate;
  int inspections = 0;
  @override
  Future<ArtifactInspection> inspectArtifacts(GeneratedProject project) async {
    inspections++;
    return inspectionGate?.future ?? ArtifactInspection.matching;
  }

  Completer<GeneratedProject>? generationGate;
  Completer<Uri>? previewGate;
  Future<void> Function()? afterResolve;
  Future<void> Function()? beforeGenerationWrite;
  int cancellations = 0;
  @override
  void cancelVerification() {
    cancellations++;
  }

  int writes = 0;
  bool failAfterResolveEvidence = false;
  bool throwAnalyze = false;
  final operations = <String>[];
  int generations = 0, verifications = 0;
  bool? lastResume;
  bool failVerification = false, disposed = false, server = false;
  @override
  bool supported = true;
  @override
  Future<GeneratedProject> generate({
    required StudioProject project,
    required AppDefinition definition,
    required String parent,
    required String name,
    required String sdk,
    required String python,
    void Function()? authorizeWrite,
  }) async {
    generations++;
    await beforeGenerationWrite?.call();
    authorizeWrite?.call();
    writes++;
    return generationGate == null ? generated : generationGate!.future;
  }

  @override
  Future<GeneratedProject> verify(
    GeneratedProject project,
    GenerationProgress progress, {
    bool resume = false,
  }) async {
    verifications++;
    lastResume = resume;
    await progress(
      project.copy(phase: SourceGenerationPhase.verifying, failedOperation: ''),
    );
    if (failVerification) throw StateError('Missing interpreter');
    var current = project.copy(
      steps: resume ? project.steps : const [],
      failedOperation: '',
      checkpointVersion: 1,
    );
    for (final operation in [
      'resolve',
      'analyze',
      'test',
      'build',
    ].skip(current.steps.length)) {
      await progress(current.copy(phase: SourceGenerationPhase.verifying));
      operations.add(operation);
      if (throwAnalyze && operation == 'analyze') {
        await progress(
          current.copy(
            phase: SourceGenerationPhase.failed,
            failedOperation: operation,
            error: 'Interpreter unavailable',
          ),
        );
        throw StateError('Interpreter unavailable');
      }
      current = current.copy(
        steps: [
          ...current.steps,
          GenerationStep(operation: operation, exitCode: 0, output: 'fixture'),
        ],
      );
      if (operation == 'resolve') await afterResolve?.call();
      await progress(current.copy(phase: SourceGenerationPhase.verifying));
      if (operation == 'resolve' && failAfterResolveEvidence) {
        throw StateError('Linked dependency metadata is not accepted.');
      }
    }
    final ready = current.copy(
      phase: SourceGenerationPhase.ready,
      outputs: {'index.html': '0' * 64, 'main.dart.js': '0' * 64},
    );
    await progress(ready);
    return ready;
  }

  @override
  Future<Uri> startPreview(GeneratedProject project) async {
    final uri = previewGate == null
        ? Uri.parse('http://127.0.0.1:1234/token/')
        : await previewGate!.future;
    server = true;
    return uri;
  }

  @override
  Future<void> openPreview(Uri uri) async {}
  @override
  Future<void> stopPreview() async {
    server = false;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await stopPreview();
  }
}

class BuildFolderPicker extends FolderPicker {
  Future<String?> Function() action = () async => '/selected';
  int calls = 0;
  @override
  bool get supported => true;
  @override
  Future<String?> pick() {
    calls++;
    return action();
  }
}

void main() {
  late FixtureHost host;
  late SourceGenerationStore store;
  late SourceGenerationController c;
  Future<bool> generate(bool approved) => c.generate(
    parent: '/parent',
    name: 'new_app',
    sdk: '/sdk',
    python: 'python3',
    approved: approved,
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    host = FixtureHost();
    store = SourceGenerationStore(
      PreferenceRecords(await SharedPreferences.getInstance()),
    );
    await StudioStore(store.records).save([project]);
    await ApplicationStore(store.records)
        .save(project.id, const ApplicationSnapshot(definition, [], 1));
    final plans = [
      ChatMessage(
        role: 'assistant',
        content:
            'Build the fixed Flutter starter.\n${BuildPlan.starterContract}',
        planContext: PlanApprovalStore(store.records).contextFor(project),
      ),
    ];
    await ConversationStore(store.records).save('p', plans);
    await PlanApprovalStore(store.records).save(project, plans, true);
    c = SourceGenerationController(
      project: project,
      definition: definition,
      store: store,
      host: host,
    );
  });
  tearDown(() {
    if (!c.isDisposed) c.dispose();
  });

  for (final key in ['studio.planApproval.v1.p', 'studio.chat.v1.p']) {
    test('Build plan status keeps corrupt $key private and recovers', () async {
      expect(await generate(true), isTrue);
      await c.startPreview();
      final working = c.result;
      final preview = c.preview;
      final history = store.records.getString('studio.generation.v1.p');
      final original = store.records.getString(key)!;
      const privateDetails = 'private-prompt token-secret /private/model';
      await store.records.setString(key, privateDetails);
      var notifications = 0;
      c.addListener(() => notifications++);
      for (var read = 0; read < 2; read++) {
        final status = c.planStatus;
        expect(status, contains('Build is locked'));
        for (final marker in [
          'private-prompt',
          'token-secret',
          '/private/model',
        ]) {
          expect(status, isNot(contains(marker)));
        }
        expect(status, contains('Plan'));
        expect(store.records.getString(key), privateDetails);
        expect(c.result, same(working));
        expect(c.preview, preview);
        expect(store.records.getString('studio.generation.v1.p'), history);
      }
      expect(notifications, 0);
      await store.records.setString(key, original);
      expect(c.planStatus, contains('Current saved plan approved'));
      expect(host.generations, 1);
      expect(host.verifications, 1);
      c.dispose();
      await store.records.setString(key, privateDetails);
      expect(c.planStatus, isNot(contains('private-prompt')));
      expect(notifications, 0);
    });
  }

  for (final failure in ['history', 'settings']) {
    test(
      'Build $failure initialization failure is private and recoverable',
      () async {
        expect(await generate(true), isTrue);
        final saved = store.records.getString('${store.prefix}p');
        final runtime = store.records.getString('studio.runtimeSetup.v1');
        const privateDetails = 'private-prompt token-secret /private/model';
        final failingStore = InitializationHistory(store.records);
        if (failure == 'settings') {
          await store.records.setString(
            'studio.runtimeSetup.v1',
            privateDetails,
          );
        } else {
          failingStore.fail = true;
        }
        c.dispose();
        host = FixtureHost();
        c = SourceGenerationController(
          project: project,
          definition: definition,
          store: failingStore,
          host: host,
        );
        expect(c.available, isFalse);
        expect(c.error, isNotNull);
        for (final marker in privateDetails.split(' ')) {
          expect(c.error, isNot(contains(marker)));
        }
        expect(c.error, contains('Reopen Build'));
        final error = c.error;
        final picker = BuildFolderPicker();
        expect(await generate(true), isFalse);
        expect(await c.verifyAgain(approved: true), isFalse);
        expect(await c.chooseDirectory(picker), isNull);
        expect(c.canRollback(store.history('p').first), isFalse);
        expect(c.createSourceReview(), isNull);
        expect(picker.calls, 0);
        expect(host.generations, 0);
        expect(host.verifications, 0);
        expect(c.error, error);
        expect(store.records.getString('${store.prefix}p'), saved);
        if (failure == 'settings') {
          expect(
            store.records.getString('studio.runtimeSetup.v1'),
            privateDetails,
          );
          await store.records.setString(
            'studio.runtimeSetup.v1',
            runtime ??
                jsonEncode({
                  'python': 'python3',
                  'modelPath': '',
                  'repository': '',
                  'downloadParent': '',
                  'revision': 'main',
                }),
          );
        }
        failingStore.fail = false;
        expect(await generate(true), isFalse);
        expect(c.error, error);
        c.dispose();
        c = SourceGenerationController(
          project: project,
          definition: definition,
          store: failingStore,
          host: FixtureHost(),
        );
        expect(c.available, isTrue);
        expect(c.error, isNull);
        expect(
          jsonEncode(c.result!.toJson()),
          jsonEncode(store.load('p')!.toJson()),
        );
        expect(store.records.getString('${store.prefix}p'), saved);
      },
    );
  }

  test(
    'Build picker failure is private and retry preserves generated history',
    () async {
      expect(await generate(true), isTrue);
      final result = c.result;
      final history = jsonEncode(
        c.buildHistory.map((e) => e.toJson()).toList(),
      );
      final picker = BuildFolderPicker()
        ..action = () async =>
            throw StateError('private-prompt token-secret /private/model');
      expect(await c.chooseDirectory(picker), isNull);
      expect(c.error, isNotNull);
      for (final marker in [
        'private-prompt',
        'token-secret',
        '/private/model',
      ]) {
        expect(c.error, isNot(contains(marker)));
      }
      expect(c.error, contains('Retry'));
      expect(c.result, same(result));
      expect(
        jsonEncode(c.buildHistory.map((e) => e.toJson()).toList()),
        history,
      );
      picker.action = () async => '/selected';
      expect(await c.chooseDirectory(picker), '/selected');
      expect(c.error, isNull);
      expect(c.result, same(result));
      picker.action = () async => null;
      expect(await c.chooseDirectory(picker), isNull);
      expect(c.error, isNull);
    },
  );

  test(
    'Build picker excludes overlap and suppresses disposed late failures',
    () async {
      final gate = Completer<String?>();
      final picker = BuildFolderPicker()..action = () => gate.future;
      var notifications = 0;
      c.addListener(() => notifications++);
      final pending = c.chooseDirectory(picker);
      expect(c.busy, isTrue);
      expect(await c.chooseDirectory(picker), isNull);
      expect(picker.calls, 1);
      c.dispose();
      final before = notifications;
      gate.completeError(
        StateError('private-prompt token-secret /private/model'),
      );
      expect(await pending, isNull);
      expect(c.error, isNull);
      expect(c.busy, isFalse);
      expect(notifications, before);
    },
  );

  test('artifact inspection is read-only, excludes overlap and ignores disposed results', () async {
    expect(await generate(true), isTrue);
    final entry = c.buildHistory.single;
    final stored = store.records.getString('studio.generation.v1.p');
    await c.startPreview();
    final preview = c.preview;
    host.inspectionGate = Completer<ArtifactInspection>();
    final inspecting = c.inspectArtifacts(entry);
    expect(c.busy, isTrue);
    await c.inspectArtifacts(entry);
    expect(host.inspections, 1);
    expect(await generate(true), isFalse);
    host.inspectionGate!.complete(ArtifactInspection.stale);
    await inspecting;
    expect(c.artifactInspection(entry), ArtifactInspection.stale);
    expect(c.preview, preview);
    expect(store.records.getString('studio.generation.v1.p'), stored);
    host.inspectionGate = Completer<ArtifactInspection>();
    final delayed = c.inspectArtifacts(entry);
    c.dispose();
    host.inspectionGate!.complete(ArtifactInspection.matching);
    await delayed;
    expect(c.artifactInspection(entry), ArtifactInspection.stale);
  });

  Future<void> savedCheckpoint({int version = 1, String pending = ''}) async {
    final approval = PlanApprovalStore(store.records)
        .requireCurrentApproval(project);
    await store.save(
      'p',
      generated.copy(
        phase: SourceGenerationPhase.verifying,
        checkpointVersion: version,
        pendingOperation: pending,
        approval: approval,
        tasks: BuildTask.starter,
        steps: const [
          GenerationStep(operation: 'resolve', exitCode: 0, output: 'saved'),
        ],
      ),
    );
    c.dispose();
    c = SourceGenerationController(
      project: project,
      definition: definition,
      store: store,
      host: host,
    );
  }

  test(
    'resume reopens successful evidence and requires separate consent',
    () async {
      await savedCheckpoint();
      expect(await c.verifyAgain(approved: false, resume: true), isFalse);
      expect(host.verifications, 0);
      expect(await c.verifyAgain(approved: true, resume: true), isTrue);
      expect(host.lastResume, isTrue);
      expect(host.operations, ['analyze', 'test', 'build']);
      expect(store.load('p')!.steps.first.output, 'saved');
      expect(await c.verifyAgain(approved: true, resume: true), isFalse);
      expect(host.verifications, 1);
    },
  );

  test('resume rejects legacy, uncertain, changed toolchain and stale approval before host work', () async {
    await savedCheckpoint(version: 0);
    expect(await c.verifyAgain(approved: true, resume: true), isFalse);
    await savedCheckpoint(pending: 'analyze');
    expect(await c.verifyAgain(approved: true, resume: true), isFalse);
    await savedCheckpoint();
    expect(
      await c.verifyAgain(approved: true, resume: true, sdk: '/different'),
      isFalse,
    );
    final plans = ConversationStore(store.records).load('p');
    await PlanApprovalStore(store.records).save(project, plans, false);
    expect(await c.verifyAgain(approved: true, resume: true), isFalse);
    expect(host.verifications, 0);
    expect(store.load('p')!.steps.single.output, 'saved');
  });

  testWidgets(
    'reopened checkpoint offers explicit resume with retained results',
    (tester) async {
      await savedCheckpoint();
      await tester.pumpWidget(
        MaterialApp(home: SourceGenerationScreen(controller: c)),
      );
      final resume = find.widgetWithText(
        OutlinedButton,
        'Resume remaining checks',
      );
      await tester.scrollUntilVisible(
        resume,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(tester.widget<OutlinedButton>(resume).onPressed, isNull);
      final consent = find.byType(CheckboxListTile);
      await tester.scrollUntilVisible(
        consent,
        -250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(consent);
      await tester.pump();
      await tester.scrollUntilVisible(
        resume,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(resume);
      await tester.pumpAndSettle();
      expect(host.lastResume, isTrue);
      expect(host.operations, ['analyze', 'test', 'build']);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'reopened uncertain dispatch explains retry without host effects',
    (tester) async {
      c.dispose();
      await store.save(
        'p',
        generated.copy(
          phase: SourceGenerationPhase.failed,
          pendingOperation: 'resolve',
          failedOperation: 'resolve',
          error: 'Runner outcome unknown',
        ),
      );
      c = SourceGenerationController(
        project: project,
        definition: definition,
        store: store,
        host: host,
      );
      expect(c.result!.pendingOperation, 'resolve');
      await tester.pumpWidget(
        MaterialApp(home: SourceGenerationScreen(controller: c)),
      );
      final marker = find.byKey(const ValueKey('pendingOperationCheckpoint'));
      await tester.scrollUntilVisible(
        marker,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(marker, findsOneWidget);
      expect(find.textContaining('Retry restarts all checks'), findsOneWidget);
      expect(host.verifications, 0);
      expect(host.writes, 0);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('Stop retains completed evidence, blocks downstream and allows explicit retry', () async {
    final reached = Completer<void>(), release = Completer<void>();
    host.afterResolve = () async {
      reached.complete();
      await release.future;
    };
    final running = generate(true);
    await reached.future;
    c.stopVerification();
    c.stopVerification();
    expect(c.stopRequested, isTrue);
    expect(c.busy, isTrue);
    expect(host.cancellations, 1);
    release.complete();
    expect(await running, isFalse);
    expect(host.operations, ['resolve']);
    expect(store.load('p')!.phase, SourceGenerationPhase.failed);
    expect(store.load('p')!.steps.single.operation, 'resolve');
    expect(store.load('p')!.error, contains('stopped by user'));
    expect(c.busy, isFalse);
    host.afterResolve = null;
    expect(await c.verifyAgain(approved: true), isTrue);
    expect(c.stopRequested, isFalse);
  });

  test(
    'Stop during final durable Ready write cannot publish success',
    () async {
      c.dispose();
      host = FixtureHost();
      final gated = StopDuringReadyStore(store.records);
      c = SourceGenerationController(
        project: project,
        definition: definition,
        store: gated,
        host: host,
      );
      gated.onReady = c.stopVerification;
      c.stopVerification();
      expect(host.cancellations, 0);
      expect(await generate(true), isFalse);
      expect(store.load('p')!.phase, SourceGenerationPhase.failed);
      expect(store.load('p')!.steps.length, 4);
      expect(store.load('p')!.error, contains('stopped by user'));
      expect(c.preview, isNull);
    },
  );

  testWidgets('Stop button disables while waiting for verification to stop', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
    final reached = Completer<void>(), release = Completer<void>();
    host.afterResolve = () async {
      reached.complete();
      await release.future;
    };
    await tester.pumpWidget(
      MaterialApp(home: SourceGenerationScreen(controller: c)),
    );
    final running = generate(true);
    await tester.pump();
    await tester.runAsync(() => reached.future);
    await tester.pump();
    final stop = find.text('Stop verification');
    await tester.scrollUntilVisible(
      stop,
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(stop);
    await tester.pump();
    expect(find.text('Stopping verification…'), findsOneWidget);
    expect(host.cancellations, 1);
    release.complete();
    await tester.pumpAndSettle();
    expect(await running, isFalse);
    expect(find.text('Stopping verification…'), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final variant in [0, 1, 2, 3]) {
    final manuallyDone = variant.isOdd;
    final shared = variant >= 2;
    test(
      'board provenance persists and changed board refuses retry before host effects done=$manuallyDone shared=$shared',
      () async {
        final boards = RequirementsStore(store.records);
        await boards.save(
          project.id,
          boards.load(project.id),
          shared
              ? sharedBoard(done: manuallyDone)
              : mappedBoard(done: manuallyDone),
        );
        // This fixture runs canonical order; approve the equivalent graph in that order.
        final contract = shared ? sharedContract() : boardContract();
        final tasks = (contract['tasks'] as List).cast<Map>();
        contract['tasks'] = [tasks[0], tasks[2], tasks[1], tasks[3]];
        final plans = [
          ChatMessage(
            role: 'assistant',
            content: boardContent(contract),
            planContext: PlanApprovalStore(store.records).contextFor(project),
          ),
        ];
        await ConversationStore(store.records).save(project.id, plans);
        await PlanApprovalStore(store.records).save(project, plans, true);
        expect(
          c.planStatus,
          contains('board task: ${shared ? 'Tstarter' : 'Tbuild'}'),
        );
        expect(await generate(true), isTrue);
        expect(store.load(project.id)!.tasks!.map((t) => t.boardTaskId), [
          if (shared)
            ...List.filled(4, 'Tstarter')
          else ...[
            'Tresolve',
            'Tanalyze',
            'Ttest',
            'Tbuild',
          ],
        ]);
        expect(
          boards
              .load(project.id)
              .tasks
              .every((t) => (t.status == TaskStatus.done) == manuallyDone),
          isTrue,
        );
        c.dispose();
        c = SourceGenerationController(
          project: project,
          definition: definition,
          store: store,
          host: host,
        );
        expect(
          c.result!.tasks!.last.boardTaskId,
          shared ? 'Tstarter' : 'Tbuild',
        );
        expect(await c.verifyAgain(approved: true), isTrue);
        final verifications = host.verifications;
        host.server = true;
        final original = boards.load(project.id);
        await boards.save(
          project.id,
          original,
          RequirementsBoard(requirements: original.requirements),
        );
        final durable = store.records.getString('studio.generation.v1.p');
        expect(await c.verifyAgain(approved: true), isFalse);
        expect(host.verifications, verifications);
        expect(host.server, isTrue);
        expect(store.records.getString('studio.generation.v1.p'), durable);
        expect(await generate(true), isFalse);
        expect(host.generations, 1);
        final invalidPlans = [
          ChatMessage(
            role: 'assistant',
            content: boardContent(contract),
            planContext: PlanApprovalStore(store.records).contextFor(project),
          ),
        ];
        await ConversationStore(store.records).save(project.id, invalidPlans);
        await PlanApprovalStore(store.records)
            .save(project, invalidPlans, true);
        expect(await generate(true), isFalse);
        expect(host.generations, 1);
        expect(host.server, isTrue);
        expect(store.records.getString('studio.generation.v1.p'), durable);
      },
    );
  }

  test('runner failure survives controller failure save and reopen', () async {
    host.throwAnalyze = true;
    expect(await generate(true), isFalse);
    expect(c.result!.failedOperation, 'analyze');
    expect(c.result!.steps.length, 1);
    c.dispose();
    host = FixtureHost();
    c = SourceGenerationController(
      project: project,
      definition: definition,
      store: store,
      host: host,
    );
    expect(
      c.result!.taskStatus(c.result!.tasks![1], active: false),
      BuildTaskStatus.failed,
    );
    expect(
      c.result!.taskStatus(c.result!.tasks![2], active: false),
      BuildTaskStatus.blocked,
    );
    expect(await c.verifyAgain(approved: true), isTrue);
    expect(store.load(project.id)!.failedOperation, isEmpty);
  });

  for (final change in ['withdraw', 'prototype', 'dispose']) {
    test('generation write guard rejects $change after preparation', () async {
      expect(await generate(true), isTrue);
      final previous = store.records.getString('studio.generation.v1.p');
      expect(previous, isNotNull);
      final writes = host.writes;
      final verifications = host.verifications;
      host.beforeGenerationWrite = () async {
        if (change == 'withdraw') {
          await PlanApprovalStore(store.records)
              .save(project, ConversationStore(store.records).load('p'), false);
        } else if (change == 'prototype') {
          await ApplicationStore(store.records)
              .save('p', const ApplicationSnapshot(definition, [], 2));
        } else {
          c.dispose();
        }
      };
      expect(await generate(true), isFalse);
      expect(host.writes, writes);
      expect(host.verifications, verifications);
      expect(store.records.getString('studio.generation.v1.p'), previous);
      if (change != 'dispose') expect(c.error, contains('preserved'));
    });
  }

  test(
    'changed prototype and stale Build inputs preserve preview and history',
    () async {
      expect(await generate(true), isTrue);
      await c.startPreview();
      final preview = c.preview;
      final history = store.records.getString('studio.generation.v1.p');
      final before = host.generations;
      final verifications = host.verifications;
      const changed = AppDefinition(
        title: 'Changed',
        theme: 'pink',
        elements: [
          AppElement(
            id: 'heading',
            kind: ElementKind.heading,
            label: 'Changed',
          ),
        ],
      );
      await ApplicationStore(store.records)
          .save(project.id, const ApplicationSnapshot(changed, [], 2));
      expect(await generate(true), isFalse);
      expect(await c.verifyAgain(approved: true), isFalse);
      // Even a fresh approval cannot authorize an old screen's definition.
      final plans = [
        ChatMessage(
          role: 'assistant',
          content: BuildPlan.starterContract,
          planContext: PlanApprovalStore(store.records).contextFor(project),
        ),
      ];
      await ConversationStore(store.records).save(project.id, plans);
      await PlanApprovalStore(store.records).save(project, plans, true);
      expect(await generate(true), isFalse);
      expect(c.error, contains('saved prototype changed'));
      expect(c.preview, preview);
      expect(host.server, isTrue);
      expect(host.generations, before);
      expect(host.verifications, verifications);
      expect(store.records.getString('studio.generation.v1.p'), history);
      c.dispose();
      c = SourceGenerationController(
        project: project,
        definition: changed,
        store: store,
        host: host,
      );
      expect(await generate(true), isTrue);
    },
  );

  test('approved prose or invalid contracts cannot stop preview or overwrite history', () async {
    expect(await generate(true), isTrue);
    await c.startPreview();
    final history = store.records.getString('studio.generation.v1.p');
    for (final text in [
      'Build anything',
      '```asg-build\n{}\n```',
      BuildPlan.starterContract.replaceFirst(
        '"version":1',
        '"version":2,"version":1',
      ),
      '${BuildPlan.starterContract}\n${BuildPlan.starterContract}',
    ]) {
      final plans = [
        ChatMessage(
          role: 'assistant',
          content: text,
          planContext: PlanApprovalStore(store.records).contextFor(project),
        ),
      ];
      await ConversationStore(store.records).save('p', plans);
      await PlanApprovalStore(store.records).save(project, plans, true);
      expect(c.planStatus, contains('Build is locked'));
      expect(await generate(true), isFalse);
      expect(await c.verifyAgain(approved: true), isFalse);
      expect(host.generations, 1);
      expect(host.verifications, 1);
      expect(host.server, isTrue);
      expect(c.preview, isNotNull);
      expect(store.records.getString('studio.generation.v1.p'), history);
      expect(c.error, contains('structured starter Plan'));
    }
  });

  test('current approved named graph drives generation and retry after reopen', () async {
    final tasks = [
      for (final task in BuildTask.starter)
        {
          'id': 'task-${task.operation.name}',
          'operation': task.operation.name,
          'dependencies': [
            for (final dep in task.dependencies)
              dep.replaceFirst('starter-', 'task-'),
          ],
        },
    ];
    final content =
        '```asg-build\n${jsonEncode({'version': 2, 'adapter': 'flutter-starter', 'tasks': tasks})}\n```';
    final plans = [
      ChatMessage(
        role: 'assistant',
        content: content,
        planContext: PlanApprovalStore(store.records).contextFor(project),
      ),
    ];
    await ConversationStore(store.records).save('p', plans);
    await PlanApprovalStore(store.records).save(project, plans, true);
    expect(
      c.planStatus,
      contains('task-test: Run tests; depends on: task-analyze'),
    );
    expect(await generate(true), isTrue);
    expect(store.load('p')!.tasks!.map((t) => t.id), tasks.map((t) => t['id']));
    c.dispose();
    c = SourceGenerationController(
      project: project,
      definition: definition,
      store: store,
      host: host,
    );
    expect(await c.verifyAgain(approved: true), isTrue);
    expect(store.load('p')!.approval!.content, content);
  });

  test(
    'retry refuses a stored task graph changed independently of approval',
    () async {
      expect(await generate(true), isTrue);
      final saved = store.load('p')!;
      final tasks = saved.tasks!.map((t) => t.toJson()).toList();
      tasks[3] = {
        ...tasks[3],
        'dependencies': ['starter-test', 'starter-resolve'],
      };
      await store.save('p', saved.copy(tasks: BuildTask.fromJson(tasks)));
      c.dispose();
      c = SourceGenerationController(
        project: project,
        definition: definition,
        store: store,
        host: host,
      );
      final history = store.records.getString('studio.generation.v1.p');
      await c.startPreview();
      expect(await c.verifyAgain(approved: true), isFalse);
      expect(host.verifications, 1);
      expect(host.server, isTrue);
      expect(store.records.getString('studio.generation.v1.p'), history);
      expect(c.error, contains('does not match'));
    },
  );

  test(
    'outcomes retain exact approval across progress failure and reopen',
    () async {
      final approval = PlanApprovalStore(store.records)
          .requireCurrentApproval(project);
      host.failVerification = true;
      expect(await generate(true), isFalse);
      final saved = store.load('p')!;
      expect(saved.approval!.matches(approval), isTrue);
      expect(saved.tasks!.map((t) => t.id), BuildTask.starter.map((t) => t.id));
      expect(
        saved.taskStatus(saved.tasks!.first, active: false),
        BuildTaskStatus.blocked,
      );
      expect(saved.phase, SourceGenerationPhase.failed);
      expect(saved.copy().approval!.matches(approval), isTrue);
      host.failVerification = false;
      c.dispose();
      c = SourceGenerationController(
        project: project,
        definition: definition,
        store: store,
        host: host,
      );
      expect(await c.verifyAgain(approved: true), isTrue);
      expect(store.load('p')!.approval!.matches(approval), isTrue);
    },
  );

  test(
    'replacement and reapproval cannot verify an older source snapshot',
    () async {
      expect(await generate(true), isTrue);
      final previous = store.records.getString('studio.generation.v1.p');
      final plans = ConversationStore(store.records).load('p');
      await PlanApprovalStore(store.records).save(project, plans, false);
      await PlanApprovalStore(store.records).save(project, plans, true);
      expect(await c.verifyAgain(approved: true), isFalse);
      expect(host.verifications, 1);
      expect(c.error, contains('Generate a new folder'));
      expect(store.records.getString('studio.generation.v1.p'), previous);
      final replacement = [
        ChatMessage(
          role: 'assistant',
          content: 'A different plan\n${BuildPlan.starterContract}',
          planContext: PlanApprovalStore(store.records).contextFor(project),
        ),
      ];
      await ConversationStore(store.records).save('p', replacement);
      await PlanApprovalStore(store.records).save(project, replacement, true);
      expect(await c.verifyAgain(approved: true), isFalse);
      expect(host.verifications, 1);
      expect(store.records.getString('studio.generation.v1.p'), previous);
      expect(await generate(true), isTrue);
      expect(
        store.load('p')!.approval!.content,
        startsWith('A different plan'),
      );
    },
  );

  test(
    'legacy and changed-input outcomes preserve history on denied retry',
    () async {
      await store.save('p', generated);
      c.dispose();
      c = SourceGenerationController(
        project: project,
        definition: definition,
        store: store,
        host: host,
      );
      expect(c.result!.approval, isNull);
      expect(await c.verifyAgain(approved: true), isFalse);
      expect(host.verifications, 0);
      expect(await generate(true), isTrue);
      final previous = store.records.getString('studio.generation.v1.p');
      c.dispose();
      c = SourceGenerationController(
        project: project,
        definition: const AppDefinition(
          title: 'Changed',
          theme: 'green',
          elements: [
            AppElement(
              id: 'heading',
              kind: ElementKind.heading,
              label: 'Changed',
            ),
          ],
        ),
        store: store,
        host: host,
      );
      expect(await c.verifyAgain(approved: true), isFalse);
      expect(host.verifications, 1);
      expect(store.records.getString('studio.generation.v1.p'), previous);
    },
  );

  test(
    'malformed or withdrawn provenance fails closed without replacement',
    () async {
      final approval = PlanApprovalStore(store.records)
          .requireCurrentApproval(project);
      for (final value in [
        null,
        {},
        {...approval.toJson(), 'approved': false},
      ]) {
        expect(
          () => GeneratedProject.fromJson({
            ...generated.toJson(),
            'approval': value,
          }),
          throwsA(anything),
        );
      }
      // Corrupt stored provenance must disable generation as well as retry.
      await store.records.setString(
        'studio.generation.v1.p',
        '{"approval":{}}',
      );
      c.dispose();
      c = SourceGenerationController(
        project: project,
        definition: definition,
        store: store,
        host: host,
      );
      expect(c.available, isFalse);
      expect(await generate(true), isFalse);
      expect(
        store.records.getString('studio.generation.v1.p'),
        '{"approval":{}}',
      );
    },
  );

  test(
    'missing, withdrawn, stale and corrupt plans reject both Build entries',
    () async {
      expect(await generate(true), isTrue);
      final previous = store.load('p');
      final key = 'studio.planApproval.v1.p';
      final valid = store.records.getString(key)!;
      await (store.records as PreferenceRecords).preferences.remove(key);
      expect(await generate(true), isFalse);
      expect(await c.verifyAgain(approved: true), isFalse);
      expect(host.generations, 1);
      expect(host.verifications, 1);
      expect(store.load('p')!.toJson(), previous!.toJson());
      for (final raw in [
        'null',
        valid.replaceFirst('"approved":true', '"approved":false'),
        '{}',
      ]) {
        await store.records.setString(key, raw);
        final generations = host.generations,
            verifications = host.verifications;
        expect(await generate(true), isFalse);
        expect(await c.verifyAgain(approved: true), isFalse);
        expect(host.generations, generations);
        expect(host.verifications, verifications);
        expect(store.load('p')!.toJson(), previous.toJson());
      }
      await store.records.setString(key, valid);
      await ConversationStore(store.records).save('p', [
        ChatMessage(
          role: 'assistant',
          content: 'Replacement plan',
          planContext: PlanApprovalStore(store.records).contextFor(project),
        ),
      ]);
      expect(await generate(true), isFalse);
      expect(await c.verifyAgain(approved: true), isFalse);
    },
  );

  test(
    'requirements revision invalidates Build and retry after screen open',
    () async {
      expect(await generate(true), isTrue);
      final previous = store.load('p')!.toJson();
      await store.records.setString(
        'studio.requirements.v1.p',
        '{"version":1,"revision":1,"requirements":[],"tasks":[]}',
      );
      expect(RequirementsStore(store.records).load('p').revision, 1);
      expect(await generate(true), isFalse);
      expect(await c.verifyAgain(approved: true), isFalse);
      expect(host.generations, 1);
      expect(host.verifications, 1);
      expect(store.load('p')!.toJson(), previous);
    },
  );

  test(
    'project changes after screen open reject a previously approved plan',
    () async {
      await StudioStore(store.records).save([]);
      expect(await generate(true), isFalse);
      expect(host.generations, 0);
      expect(c.error, contains('missing or ambiguous'));
    },
  );

  test(
    'withdrawal during generation prevents subsequent verification',
    () async {
      host.generationGate = Completer();
      final running = generate(true);
      await Future<void>.delayed(Duration.zero);
      final messages = ConversationStore(store.records).load('p');
      await PlanApprovalStore(store.records).save(project, messages, false);
      host.generationGate!.complete(generated);
      expect(await running, isFalse);
      expect(host.verifications, 0);
      expect(store.load('p')!.phase, SourceGenerationPhase.failed);
      expect(c.error, contains('Build requires'));
    },
  );

  for (final retry in [false, true]) {
    for (final change in [
      'withdraw',
      'reapprove',
      'requirements',
      'prototype',
      'corrupt',
    ]) {
      test(
        'verification stops after $change during resolve (retry=$retry)',
        () async {
          if (retry) expect(await generate(true), isTrue);
          host.operations.clear();
          host.afterResolve = () async {
            final approvals = PlanApprovalStore(store.records);
            final messages = ConversationStore(store.records).load('p');
            switch (change) {
              case 'withdraw':
                await approvals.save(project, messages, false);
              case 'reapprove':
                await approvals.save(project, messages, false);
                await approvals.save(project, messages, true);
              case 'requirements':
                await store.records.setString(
                  'studio.requirements.v1.p',
                  '{"version":1,"revision":1,"requirements":[],"tasks":[]}',
                );
              case 'prototype':
                await ApplicationStore(store.records)
                    .save('p', const ApplicationSnapshot(definition, [], 2));
              case 'corrupt':
                await store.records.setString('studio.planApproval.v1.p', '{}');
            }
          };
          expect(
            await (retry ? c.verifyAgain(approved: true) : generate(true)),
            isFalse,
          );
          expect(host.operations, ['resolve']);
          final saved = store.load('p')!;
          expect(saved.phase, SourceGenerationPhase.failed);
          expect(saved.steps.map((s) => s.operation), ['resolve']);
          expect(
            saved.taskStatus(saved.tasks![1], active: false),
            BuildTaskStatus.blocked,
          );
          final reopened = SourceGenerationController(
            project: project,
            definition: definition,
            store: store,
            host: FixtureHost(),
          );
          expect(reopened.result!.toJson(), saved.toJson());
          reopened.dispose();
        },
      );
    }
  }

  test(
    'post-resolve validation failure retains evidence across reopen',
    () async {
      host.failAfterResolveEvidence = true;
      expect(await generate(true), isFalse);
      expect(host.operations, ['resolve']);
      final saved = store.load('p')!;
      expect(saved.phase, SourceGenerationPhase.failed);
      expect(saved.steps.single.operation, 'resolve');
      expect(saved.steps.single.output, 'fixture');
      expect(
        saved.taskStatus(saved.tasks!.first, active: false),
        BuildTaskStatus.passed,
      );
      expect(
        saved.taskStatus(saved.tasks![1], active: false),
        BuildTaskStatus.blocked,
      );
      c.dispose();
      c = SourceGenerationController(
        project: project,
        definition: definition,
        store: store,
        host: FixtureHost(),
      );
      expect(c.result!.toJson(), saved.toJson());
      expect(c.result!.error, contains('Linked dependency metadata'));
    },
  );

  test('corrupt ready records cannot claim verification and snapshots are immutable', () {
    expect(
      () => GeneratedProject.fromJson(
        generated.copy(phase: SourceGenerationPhase.ready).toJson(),
      ),
      throwsFormatException,
    );
    expect(() => generated.sources.clear(), throwsUnsupportedError);
  });
  test(
    'approval and duplicate submission guards precede any generation',
    () async {
      expect(await generate(false), isFalse);
      expect(host.generations, 0);
      host.generationGate = Completer();
      final running = generate(true);
      await Future<void>.delayed(Duration.zero);
      expect(await generate(true), isFalse);
      host.generationGate!.complete(generated);
      expect(await running, isTrue);
      expect(host.generations, 1);
    },
  );
  test('thrown verification failure persists across reopening', () async {
    host.failVerification = true;
    expect(await generate(true), isFalse);
    final restored = SourceGenerationController(
      project: project,
      definition: definition,
      store: store,
      host: FixtureHost(),
    );
    expect(restored.result!.phase, SourceGenerationPhase.failed);
    expect(restored.result!.error, contains('Missing interpreter'));
    restored.dispose();
    host.failVerification = false;
    expect(await c.verifyAgain(approved: true), isTrue);
    expect(store.load('p')!.phase, SourceGenerationPhase.ready);
    expect(
      await c.verifyAgain(
        approved: true,
        python: '/new/python',
        sdk: '/new/sdk',
      ),
      isTrue,
    );
    expect(store.load('p')!.python, '/new/python');
    expect(store.load('p')!.sdk, '/new/sdk');
  });
  test('failed history write prevents all verification commands', () async {
    c.dispose();
    host = FixtureHost();
    c = SourceGenerationController(
      project: project,
      definition: definition,
      store: FailingHistory(store.records),
      host: host,
    );
    expect(await generate(true), isFalse);
    expect(host.verifications, 0);
    expect(store.load('p'), isNull);
    expect(c.error, contains('could not be saved'));
  });
  test('disposal during prepare prevents later saves and commands', () async {
    host.generationGate = Completer();
    final running = generate(true);
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    host.generationGate!.complete(generated);
    expect(await running, isFalse);
    expect(host.verifications, 0);
    expect(store.load('p'), isNull);
    expect(host.disposed, isTrue);
  });
  test('disposal during preview closes a late-bound server', () async {
    expect(await generate(true), isTrue);
    host.previewGate = Completer();
    final starting = c.startPreview();
    c.dispose();
    host.previewGate!.complete(Uri.parse('http://127.0.0.1:1234/token/'));
    await starting;
    expect(c.preview, isNull);
    expect(host.server, isFalse);
  });
  testWidgets(
    'unsupported hosts disable local generation and folder controls',
    (tester) async {
      host.supported = false;
      addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        MaterialApp(home: SourceGenerationScreen(controller: c)),
      );
      await tester.scrollUntilVisible(
        find.byTooltip('Choose Existing parent directory'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) =>
                    widget is IconButton &&
                    widget.tooltip == 'Choose Existing parent directory',
              ),
            )
            .onPressed,
        isNull,
      );
      expect(await generate(true), isFalse);
      expect(host.generations, 0);
    },
  );
  testWidgets(
    'generation UI requires explicit approval and shows real outcome',
    (tester) async {
      addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
      await tester.pumpWidget(
        MaterialApp(home: SourceGenerationScreen(controller: c)),
      );
      await tester.scrollUntilVisible(
        find.text('Generate, test and build'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      final button = find.ancestor(
        of: find.text('Generate, test and build'),
        matching: find.byWidgetPredicate((widget) => widget is FilledButton),
      );
      expect(tester.widget<FilledButton>(button).onPressed, isNull);
      await tester.ensureVisible(find.byType(Checkbox));
      await tester.tap(find.byType(Checkbox));
      await tester.pump();
      expect(tester.widget<FilledButton>(button).onPressed, isNotNull);
      await generate(true);
      await tester.pump();
      await tester.scrollUntilVisible(
        find.text('Saved outcome: ready'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Saved outcome: ready'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Plan that authorized this build'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('Plan that authorized this build')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plan that authorized this build'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Build the fixed Flutter starter.'),
        findsWidgets,
      );
      await tester.scrollUntilVisible(
        find.text('starter-build (build): passed'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('starter-build (build): passed'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Start actual built preview'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Start actual built preview'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Recorded build history'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('Recorded build history')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recorded build history'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Artifact availability is unverified'),
        findsOneWidget,
      );
      await Scrollable.ensureVisible(
        tester.element(find.textContaining(' · ready').last),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining(' · ready').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Inspect saved artifacts'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('Inspect saved artifacts')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inspect saved artifacts'));
      await tester.pumpAndSettle();
      expect(find.text(ArtifactInspection.matching.label), findsOneWidget);
    },
  );
}

class FailingHistory extends SourceGenerationStore {
  FailingHistory(super.records);
  @override
  Future<void> save(String id, GeneratedProject project) async =>
      throw StateError('History disk unavailable');
}

class StopDuringReadyStore extends SourceGenerationStore {
  StopDuringReadyStore(super.records);
  void Function()? onReady;
  @override
  Future<void> save(String id, GeneratedProject project) async {
    if (project.phase == SourceGenerationPhase.ready) onReady?.call();
    await super.save(id, project);
  }
}

class InitializationHistory extends SourceGenerationStore {
  InitializationHistory(super.records);
  bool fail = false;
  @override
  GeneratedProject? load(String id) {
    if (fail) throw StateError('private-prompt token-secret /private/model');
    return super.load(id);
  }
}
