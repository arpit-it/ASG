import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/controllers/app_workspace_controller.dart';
import 'package:asg/controllers/studio_session_controller.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/application_editor.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/services/studio_session_store.dart';
import 'package:asg/views/live_application_view.dart';
import 'package:asg/views/studio_app.dart';
import 'package:asg/views/project_workspace.dart';

const project = StudioProject(
  id: 'live-test',
  name: 'Demo',
  description: 'A task planner',
  type: 'Flutter',
  platforms: ['macOS'],
  location: '',
);
const changed = AppDefinition(
  title: 'Updated Demo',
  theme: 'green',
  elements: [
    AppElement(id: 'count', kind: ElementKind.counter, label: 'My count'),
  ],
);

class ReplyProvider implements ModelProvider {
  ReplyProvider(this.reply);
  final String reply;
  @override
  Stream<String> generate(String prompt) => Stream.value(reply);
  @override
  Future<void> cancel() async {}
}

class FailingApplicationStore extends ApplicationStore {
  FailingApplicationStore(super.preferences);
  @override
  Future<void> save(String id, ApplicationSnapshot state) async =>
      throw StateError('Disk unavailable');
}

ApplicationEditor editor(String reply) => ApplicationEditor(
  allowBuiltInEdits: false,
  createProvider: (_) => ReplyProvider(reply),
);
void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'chat update persists revision before publishing the new preview',
    () async {
      final store = ApplicationStore(await SharedPreferences.getInstance());
      final c = AppWorkspaceController(
        project,
        openStore: () async => store,
        editor: editor(
          jsonEncode({'summary': 'Added a counter', 'app': changed.toJson()}),
        ),
      );
      await c.load();
      expect(await c.apply('Add a counter'), true);
      expect(c.definition!.title, 'Updated Demo');
      expect(c.revision, 2);
      expect(c.messages.last.content, 'Added a counter');
      expect(store.load(project).definition.theme, 'green');
      c.dispose();
    },
  );
  test(
    'malformed response leaves the working preview and history unchanged',
    () async {
      final store = ApplicationStore(await SharedPreferences.getInstance());
      final c = AppWorkspaceController(
        project,
        openStore: () async => store,
        editor: editor('not JSON'),
      );
      await c.load();
      final previous = c.definition;
      expect(await c.apply('Change it'), false);
      expect(c.definition, same(previous));
      expect(c.revision, 1);
      expect(c.messages, isEmpty);
      expect(c.error, contains('last working version'));
      c.dispose();
    },
  );
  test('failed persistence does not publish a model update', () async {
    final store = FailingApplicationStore(
      await SharedPreferences.getInstance(),
    );
    final c = AppWorkspaceController(
      project,
      openStore: () async => store,
      editor: editor(
        jsonEncode({'summary': 'Changed', 'app': changed.toJson()}),
      ),
    );
    await c.load();
    expect(await c.apply('Change it'), false);
    expect(c.definition!.title, 'Demo');
    expect(c.revision, 1);
    c.dispose();
  });
  test('invalid action targets cannot enter executable application state', () {
    expect(
      () => AppDefinition.fromJson({
        'title': 'App',
        'theme': 'indigo',
        'elements': [
          {
            'id': 'bad',
            'type': 'button',
            'label': 'Bad',
            'action': 'increment',
            'target': 'missing',
          },
        ],
      }),
      throwsFormatException,
    );
  });
  test(
    'startup restores selected project rather than returning to dashboard',
    () async {
      final store = StudioStore(await SharedPreferences.getInstance());
      const second = StudioProject(
        id: 'second',
        name: 'Second',
        description: '',
        type: 'Flutter',
        platforms: ['Web'],
        location: '',
      );
      final session = StudioSessionStore(store);
      await session.select(project.id);
      final c = StudioSessionController(session, [project, second]);
      expect(c.current!.id, project.id);
      c.dispose();
    },
  );
  testWidgets('current app opens with chat left and live preview right', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = StudioStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      StudioApp(store: store, initialProjects: const [project]),
    );
    await tester.pumpAndSettle();
    expect(find.text('Apply instruction'), findsOneWidget);
    expect(find.byType(LiveApplicationView), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Chat')).dx,
      lessThan(tester.getTopLeft(find.text('Application preview')).dx),
    );
    expect(find.text('Live · v1'), findsOneWidget);
  });
  testWidgets(
    'preview controls execute real actions and preserve state on a visual update',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(body: LiveApplicationView(definition: changed)),
        ),
      );
      await tester.tap(find.byTooltip('Increase My count'));
      await tester.pump();
      expect(find.text('1'), findsOneWidget);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LiveApplicationView(
              definition: AppDefinition(
                title: 'Another title',
                theme: 'pink',
                elements: changed.elements,
              ),
            ),
          ),
        ),
      );
      expect(find.text('1'), findsOneWidget);
    },
  );
  testWidgets('applying a chat instruction refreshes the visible application', (
    tester,
  ) async {
    final store = ApplicationStore(await SharedPreferences.getInstance());
    final c = AppWorkspaceController(
      project,
      openStore: () async => store,
      editor: editor(
        jsonEncode({'summary': 'Added a counter', 'app': changed.toJson()}),
      ),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: ProjectWorkspace(project: project, controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byWidgetPredicate(
        (widget) =>
            widget is TextField &&
            widget.decoration?.hintText?.startsWith('For example:') == true,
      ),
      'Add a counter',
    );
    await tester.tap(find.text('Apply instruction'));
    await tester.pumpAndSettle();
    expect(find.text('Live · v2'), findsOneWidget);
    expect(find.text('My count'), findsOneWidget);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget is SelectableText && widget.data == 'Added a counter',
      ),
      findsOneWidget,
    );
  });
  testWidgets('phone workspace switches between chat and preview', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final store = StudioStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(
      StudioApp(store: store, initialProjects: const [project]),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Preview'));
    await tester.pumpAndSettle();
    expect(find.text('Application preview'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  test(
    'compact model operations are validated and do not mutate the original',
    () {
      final result = ApplicationEditor().applyEdits(changed, [
        {'op': 'setTitle', 'value': 'New title'},
        {'op': 'setTheme', 'value': 'pink'},
      ]);
      expect(result.title, 'New title');
      expect(result.theme, 'pink');
      expect(changed.title, 'Updated Demo');
      expect(
        () => ApplicationEditor().applyEdits(changed, [
          {'op': 'execute', 'value': 'shell'},
        ]),
        throwsFormatException,
      );
    },
  );
  testWidgets(
    'supported chat instructions update the app without an inference request',
    (tester) async {
      final store = ApplicationStore(await SharedPreferences.getInstance());
      final c = AppWorkspaceController(project, openStore: () async => store);
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectWorkspace(project: project, controller: c),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (widget) =>
              widget is TextField &&
              widget.decoration?.hintText?.startsWith('For example:') == true,
        ),
        'add a counter and change the theme to green',
      );
      await tester.tap(find.text('Apply instruction'));
      await tester.pumpAndSettle();
      expect(find.text('Live · v2'), findsOneWidget);
      expect(find.text('Counter'), findsOneWidget);
      expect(store.load(project).definition.theme, 'green');
    },
  );
  test(
    'real local Qwen instruction updates a saved application revision',
    () async {
      // This opt-in test runs alone; widget-test HTTP mocking must be disabled.
      final previousOverrides = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previousOverrides);
      final store = ApplicationStore(await SharedPreferences.getInstance());
      final c = AppWorkspaceController(
        project,
        openStore: () async => store,
        editor: ApplicationEditor(allowBuiltInEdits: false),
      );
      final phases = <String>{};
      final drafts = <String>{};
      c.addListener(() {
        phases.add(c.phase.name);
        if (c.draftResponse.isNotEmpty) drafts.add(c.draftResponse);
      });
      await c.load();
      final applied = await c.apply(
        'Change only the application title to Updated Demo and theme to green. Keep the existing elements.',
      );
      expect(applied, true, reason: c.error);
      expect(c.definition!.title, 'Updated Demo');
      expect(c.definition!.theme, 'green');
      expect(store.load(project).revision, 2);
      expect(phases, containsAll(['thinking', 'writing', 'applying']));
      expect(
        drafts.length,
        greaterThanOrEqualTo(2),
        reason: 'Human-readable output must arrive in multiple chunks',
      );
      c.dispose();
    },
    skip: !const bool.fromEnvironment('ASG_REAL_INFERENCE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
