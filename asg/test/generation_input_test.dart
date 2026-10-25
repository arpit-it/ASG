import 'dart:convert';

import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/generation_host_stub.dart';
import 'package:asg/services/generation_input.dart';
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
// Frozen fingerprints of the pre-change v1 generator's ASCII fixture payloads.
const legacyInputs = {
  'assets/app.json':
      '072f70458e8d0e6bb5ef40f30601e619903f327de95c83cc3595ae44fa6ffc95',
  'asg_project.json':
      'f19f4d591f48ad793c0c19014750673ee83a3f65a06e343bf49bbae351cd5de3',
};
GeneratedProject saved(Map<String, String> sources) => GeneratedProject(
  directory: '/generated',
  sdk: '/sdk',
  python: 'python3',
  sources: sources,
  phase: SourceGenerationPhase.ready,
  outputs: {'index.html': '0' * 64, 'main.dart.js': '0' * 64},
  steps: ['resolve', 'analyze', 'test', 'build']
      .map(
        (operation) => GenerationStep(
          operation: operation,
          exitCode: 0,
          output: 'fixture',
        ),
      )
      .toList(),
);

class SnapshotHost extends UnsupportedGenerationHost {
  int previews = 0, opens = 0;
  GeneratedProject? previewed;
  @override
  bool get supported => true;
  @override
  Future<Uri> startPreview(GeneratedProject project) async {
    previews++;
    previewed = project;
    return Uri.parse('http://127.0.0.1:1234/saved/');
  }

  @override
  Future<void> openPreview(Uri uri) async {
    opens++;
  }
}

void main() {
  test(
    'pre-change v1 payload fingerprints remain current without migration',
    () {
      final input = GenerationInput(project, definition);
      expect(input.fingerprints, legacyInputs);
      expect(
        input.compare(GeneratedProject.fromJson(saved(legacyInputs).toJson())),
        GeneratedSnapshotStatus.current,
      );
      final normalized = AppDefinition.fromJson({
        'title': 'App',
        'theme': 'green',
        'elements': [
          {'id': 'heading', 'type': 'heading', 'label': 'Welcome'},
        ],
      });
      expect(
        GenerationInput(project, normalized).compare(saved(legacyInputs)),
        GeneratedSnapshotStatus.current,
      );
      expect(() => input.fingerprints.clear(), throwsUnsupportedError);
    },
  );
  test('missing history and missing identity never claim current inputs', () {
    final input = GenerationInput(project, definition);
    expect(input.compare(null), GeneratedSnapshotStatus.none);
    expect(
      input.compare(saved({'lib/main.dart': '0' * 64})),
      GeneratedSnapshotStatus.unknown,
    );
    expect(
      input.compare(
        saved({'assets/app.json': legacyInputs['assets/app.json']!}),
      ),
      GeneratedSnapshotStatus.unknown,
    );
  });
  test('application edits and reviewed project changes mark old snapshots outdated', () {
    for (final edited in [
      AppDefinition(
        title: 'New title',
        theme: 'green',
        elements: definition.elements,
      ),
      AppDefinition(title: 'App', theme: 'pink', elements: definition.elements),
      const AppDefinition(
        title: 'App',
        theme: 'green',
        elements: [
          AppElement(
            id: 'heading',
            kind: ElementKind.heading,
            label: 'New content',
          ),
        ],
      ),
    ]) {
      expect(
        GenerationInput(project, edited).compare(saved(legacyInputs)),
        GeneratedSnapshotStatus.outdated,
      );
    }
    const changedProject = StudioProject(
      id: 'p',
      name: 'App',
      description: 'New reviewed requirement',
      type: 'Flutter',
      platforms: ['Web'],
      location: '',
    );
    expect(
      GenerationInput(changedProject, definition).compare(saved(legacyInputs)),
      GeneratedSnapshotStatus.outdated,
    );
  });
  test(
    'counter, notes and task-completion state are part of snapshot identity',
    () {
      const base = AppDefinition(
        title: 'App',
        theme: 'green',
        elements: [
          AppElement(
            id: 'count',
            kind: ElementKind.counter,
            label: 'Count',
            value: '3',
          ),
          AppElement(
            id: 'note',
            kind: ElementKind.notes,
            label: 'Notes',
            value: 'Before',
          ),
          AppElement(
            id: 'tasks',
            kind: ElementKind.taskList,
            label: 'Tasks',
            items: ['One'],
          ),
        ],
      );
      final record = saved(GenerationInput(project, base).fingerprints);
      for (final replacement in [
        const AppElement(
          id: 'count',
          kind: ElementKind.counter,
          label: 'Count',
          value: '4',
        ),
        const AppElement(
          id: 'note',
          kind: ElementKind.notes,
          label: 'Notes',
          value: 'After',
        ),
        const AppElement(
          id: 'tasks',
          kind: ElementKind.taskList,
          label: 'Tasks',
          items: ['One'],
          completed: [0],
        ),
      ]) {
        final edited = AppDefinition(
          title: base.title,
          theme: base.theme,
          elements: base.elements
              .map((e) => e.id == replacement.id ? replacement : e)
              .toList(),
        );
        expect(
          GenerationInput(project, edited).compare(record),
          GeneratedSnapshotStatus.outdated,
        );
      }
    },
  );
  test(
    'reopening compares stored history without rewriting its payload',
    () async {
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      final store = SourceGenerationStore(PreferenceRecords(preferences));
      await store.save('p', saved(legacyInputs));
      final original = preferences.getString('studio.generation.v1.p');
      final c = SourceGenerationController(
        project: project,
        definition: AppDefinition(
          title: 'Changed',
          theme: 'green',
          elements: definition.elements,
        ),
        store: store,
        host: SnapshotHost(),
      );
      expect(c.snapshotStatus, GeneratedSnapshotStatus.outdated);
      expect(preferences.getString('studio.generation.v1.p'), original);
      expect(jsonDecode(original!)['phase'], 'ready');
      c.dispose();
    },
  );

  for (final status in [
    GeneratedSnapshotStatus.current,
    GeneratedSnapshotStatus.outdated,
    GeneratedSnapshotStatus.unknown,
  ]) {
    testWidgets(
      'saved build UI labels ${status.name} and preserves explicit preview',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        final store = SourceGenerationStore(
          PreferenceRecords(await SharedPreferences.getInstance()),
        );
        final source = status == GeneratedSnapshotStatus.unknown
            ? {'lib/main.dart': '0' * 64}
            : legacyInputs;
        await store.save('p', saved(source));
        final host = SnapshotHost();
        final c = SourceGenerationController(
          project: project,
          definition: status == GeneratedSnapshotStatus.outdated
              ? AppDefinition(
                  title: 'Edited app',
                  theme: 'green',
                  elements: definition.elements,
                )
              : definition,
          store: store,
          host: host,
        );
        addTearDown(() async => tester.pumpWidget(const SizedBox.shrink()));
        await tester.pumpWidget(
          MaterialApp(home: SourceGenerationScreen(controller: c)),
        );
        await tester.scrollUntilVisible(
          find.byKey(const ValueKey('generatedSnapshotStatus')),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        final text = tester
            .widget<Text>(find.byKey(const ValueKey('generatedSnapshotStatus')))
            .data!;
        expect(
          text,
          contains(switch (status) {
            GeneratedSnapshotStatus.current => 'matches the current',
            GeneratedSnapshotStatus.outdated => 'Earlier snapshot',
            _ => 'cannot be identified',
          }),
        );
        final label = switch (status) {
          GeneratedSnapshotStatus.current => 'Start actual built preview',
          GeneratedSnapshotStatus.outdated => 'Preview earlier generated build',
          _ => 'Preview saved build (inputs unknown)',
        };
        await tester.scrollUntilVisible(
          find.text(label),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text(label));
        await tester.pumpAndSettle();
        expect(host.previews, 1);
        expect(host.previewed!.directory, '/generated');
        final open = switch (status) {
          GeneratedSnapshotStatus.current => 'Open generated app in browser',
          GeneratedSnapshotStatus.outdated => 'Open earlier build in browser',
          _ => 'Open saved build in browser',
        };
        await tester.scrollUntilVisible(
          find.text(open),
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.tap(find.text(open));
        await tester.pump();
        expect(host.opens, 1);
      },
    );
  }
}
