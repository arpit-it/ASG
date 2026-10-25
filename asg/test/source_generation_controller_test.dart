import 'dart:async';

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

class FixtureHost implements GenerationHost {
  Completer<GeneratedProject>? generationGate;
  Completer<Uri>? previewGate;
  Future<void> Function()? afterResolve;
  Future<void> Function()? beforeGenerationWrite;
  int writes = 0;
  bool failAfterResolveEvidence = false;
  final operations = <String>[];
  int generations = 0, verifications = 0;
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
    GenerationProgress progress,
  ) async {
    verifications++;
    await progress(project.copy(phase: SourceGenerationPhase.verifying));
    if (failVerification) throw StateError('Missing interpreter');
    var current = project.copy(steps: const []);
    for (final operation in ['resolve', 'analyze', 'test', 'build']) {
      await progress(current.copy(phase: SourceGenerationPhase.verifying));
      operations.add(operation);
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
      await tester.tap(find.text('Plan that authorized this build'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Build the fixed Flutter starter.'),
        findsWidgets,
      );
      await tester.scrollUntilVisible(
        find.text('starter-build: passed'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('starter-build: passed'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Start actual built preview'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Start actual built preview'), findsOneWidget);
    },
  );
}

class FailingHistory extends SourceGenerationStore {
  FailingHistory(super.records);
  @override
  Future<void> save(String id, GeneratedProject project) async =>
      throw StateError('History disk unavailable');
}
