import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/app_workspace_controller.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/views/live_application_view.dart';
import 'package:asg/views/project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const project = StudioProject(
  id: 'p',
  name: 'Demo',
  description: '',
  type: 'Flutter',
  platforms: [],
  location: '',
);
const initial = AppDefinition(
  title: 'Demo',
  theme: 'green',
  elements: [
    AppElement(id: 'counter', kind: ElementKind.counter, label: 'Count'),
    AppElement(
      id: 'tasks',
      kind: ElementKind.taskList,
      label: 'Tasks',
      items: ['One', 'Two'],
    ),
    AppElement(id: 'notes', kind: ElementKind.notes, label: 'Notes'),
  ],
);

void main() {
  testWidgets(
    'counter, task completion, removal and notes survive view recreation',
    (tester) async {
      AppDefinition latest = initial;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveApplicationView(
              definition: initial,
              onStateChanged: (value) => latest = value,
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Increase Count'));
      await tester.pump();
      expect(latest.elements[0].value, '1');
      await tester.tap(find.byTooltip('Decrease Count'));
      await tester.pump();
      expect(latest.elements[0].value, '0');
      await tester.tap(find.byType(Checkbox).last);
      await tester.pump();
      expect(latest.elements[1].completed, [1]);
      await tester.tap(find.byTooltip('Remove item').first);
      await tester.pump();
      expect(latest.elements[1].items, ['Two']);
      expect(latest.elements[1].completed, [0]);
      await tester.enterText(find.byType(TextFormField), 'Saved note');
      await tester.pump();
      final restored = AppDefinition.fromJson(
        jsonDecode(jsonEncode(latest.toJson())) as Map<String, dynamic>,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveApplicationView(
              key: const ValueKey('reopen'),
              definition: restored,
            ),
          ),
        ),
      );
      await tester.pump();
      expect(tester.widget<Checkbox>(find.byType(Checkbox)).value, isTrue);
      expect(find.text('Two'), findsOneWidget);
      expect(find.text('Saved note'), findsOneWidget);
    },
  );

  test(
    'rapid changes serialize and save latest state before chat update',
    () async {
      SharedPreferences.setMockInitialValues({});
      final records = PreferenceRecords(await SharedPreferences.getInstance());
      final store = DelayedStore(records);
      final c = AppWorkspaceController(project, openStore: () async => store);
      await c.load();
      final first = c.recordRuntimeState(initial);
      final latest = AppDefinition(
        title: 'Latest',
        theme: 'green',
        elements: initial.elements,
      );
      final second = c.recordRuntimeState(latest);
      expect(c.savingInteractions, isTrue);
      store.gate.complete();
      await Future.wait([first, second]);
      expect(store.maxConcurrent, 1);
      expect(store.load(project).definition.title, 'Latest');
      expect(await c.apply('change theme to pink'), isTrue);
      expect(store.load(project).definition.title, 'Latest');
      expect(store.load(project).revision, 2);
      c.dispose();
    },
  );

  testWidgets(
    'changing text into notes with same id/value persists typed text',
    (tester) async {
      AppDefinition? latest;
      const text = AppDefinition(
        title: 'Demo',
        theme: 'green',
        elements: [
          AppElement(id: 'same', kind: ElementKind.text, label: 'Text'),
        ],
      );
      const notes = AppDefinition(
        title: 'Demo',
        theme: 'green',
        elements: [
          AppElement(id: 'same', kind: ElementKind.notes, label: 'Notes'),
        ],
      );
      Widget view(AppDefinition value) => MaterialApp(
        home: Scaffold(
          body: LiveApplicationView(
            definition: value,
            onStateChanged: (value) => latest = value,
          ),
        ),
      );
      await tester.pumpWidget(view(text));
      await tester.pumpWidget(view(notes));
      await tester.enterText(find.byType(TextFormField), 'Keep this');
      expect(latest!.elements.single.value, 'Keep this');
    },
  );

  testWidgets('busy preview disables focused keyboard editing', (tester) async {
    var reports = 0;
    Widget view(bool enabled) => MaterialApp(
      home: Scaffold(
        body: LiveApplicationView(
          definition: initial,
          enabled: enabled,
          onStateChanged: (_) => reports++,
        ),
      ),
    );
    await tester.pumpWidget(view(true));
    await tester.tap(find.byType(TextFormField));
    await tester.enterText(find.byType(TextFormField), 'Before');
    expect(reports, 1);
    await tester.pumpWidget(view(false));
    await tester.pump();
    final notes = tester.widget<TextFormField>(find.byType(TextFormField));
    expect(notes.enabled, isFalse);
    expect(tester.testTextInput.hasAnyClients, isFalse);
    expect(
      tester.widget<Checkbox>(find.byType(Checkbox).first).onChanged,
      isNull,
    );
  });

  test(
    'chat waits for a pending interaction write before using its state',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = DelayedStore(
        PreferenceRecords(await SharedPreferences.getInstance()),
      );
      final c = AppWorkspaceController(project, openStore: () async => store);
      await c.load();
      final interaction = c.recordRuntimeState(initial);
      final apply = c.apply('change theme to pink');
      expect(c.busy, isTrue);
      expect(c.revision, 1);
      store.gate.complete();
      await interaction;
      expect(await apply, isTrue);
      final saved = store.load(project);
      expect(saved.definition.elements[1].items, ['One', 'Two']);
      expect(saved.messages.length, 2);
      expect(saved.revision, 2);
      c.dispose();
    },
  );

  testWidgets('navigation waits for pending preview writes', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final records = PreferenceRecords(await SharedPreferences.getInstance());
    await ApplicationStore(records)
        .save('p', const ApplicationSnapshot(initial, [], 1));
    final store = DelayedStore(records);
    final c = AppWorkspaceController(project, openStore: () async => store);
    var pending = false;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ProjectWorkspace(
                    project: project,
                    controller: c,
                    onPendingChanged: (value) => pending = value,
                  ),
                ),
              ),
              child: const Text('Open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Increase Count'));
    await tester.pump();
    expect(pending, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Apply instruction'), findsOneWidget);
    store.gate.complete();
    await tester.pumpAndSettle();
    expect(pending, isFalse);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Open'), findsOneWidget);
    expect(store.load(project).definition.elements[0].value, '1');
  });

  testWidgets('pending save disables preview immediately when chat starts', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final records = PreferenceRecords(await SharedPreferences.getInstance());
    await ApplicationStore(records)
        .save('p', const ApplicationSnapshot(initial, [], 1));
    final store = DelayedStore(records);
    final c = AppWorkspaceController(project, openStore: () async => store);
    var pending = false;
    await tester.pumpWidget(
      MaterialApp(
        home: ProjectWorkspace(
          project: project,
          controller: c,
          onPendingChanged: (value) => pending = value,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Increase Count'));
    await tester.pump();
    final applying = c.apply('change theme to pink');
    await tester.pump();
    expect(
      tester
          .widget<LiveApplicationView>(find.byType(LiveApplicationView))
          .enabled,
      isFalse,
    );
    expect(pending, isTrue);
    expect(
      tester.widget<TextFormField>(find.byType(TextFormField)).enabled,
      isFalse,
    );
    store.gate.complete();
    await tester.pumpAndSettle();
    expect(await applying, isTrue);
    expect(c.definition!.elements[0].value, '1');
    expect(pending, isFalse);
  });

  test(
    'old definitions default completion and reject invalid completion indexes',
    () {
      final json = initial.toJson();
      final elements = json['elements'] as List;
      (elements[1] as Map).remove('completed');
      expect(AppDefinition.fromJson(json).elements[1].completed, isEmpty);
      (elements[1] as Map)['completed'] = [5];
      expect(() => AppDefinition.fromJson(json), throwsFormatException);
    },
  );
}

class DelayedStore extends ApplicationStore {
  DelayedStore(super.records);
  final gate = Completer<void>();
  int concurrent = 0, maxConcurrent = 0;
  @override
  Future<void> save(String id, ApplicationSnapshot state) async {
    concurrent++;
    if (concurrent > maxConcurrent) maxConcurrent = concurrent;
    await gate.future;
    try {
      await super.save(id, state);
    } finally {
      concurrent--;
    }
  }
}
