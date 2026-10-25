import 'dart:async';

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
    'lib/main.dart':
        '0000000000000000000000000000000000000000000000000000000000000000',
  },
);

class FixtureHost implements GenerationHost {
  Completer<GeneratedProject>? generationGate;
  Completer<Uri>? previewGate;
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
  }) async {
    generations++;
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
    final ready = project.copy(
      phase: SourceGenerationPhase.ready,
      steps: ['resolve', 'analyze', 'test', 'build']
          .map(
            (operation) => GenerationStep(
              operation: operation,
              exitCode: 0,
              output: 'fixture',
            ),
          )
          .toList(),
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
