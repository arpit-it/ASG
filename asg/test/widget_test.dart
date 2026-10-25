import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/services/execution_policy.dart';
import 'package:asg/views/studio_app.dart';
import 'package:asg/views/model_chat.dart';

void main() {
  test('records survive repository reload', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final store = StudioStore(preferences);
    await store.save([
      const StudioProject(
        id: '1',
        name: 'Task manager',
        description: 'Tasks',
        type: 'Flutter',
        platforms: ['Web'],
        location: '',
      ),
    ]);
    expect(StudioStore(preferences).load().single.name, 'Task manager');
  });
  test('build requires explicit plan approval', () {
    final policy = ExecutionPolicy();
    for (final mode in ConversationMode.values) {
      expect(policy.canModifyFiles(mode, planApproved: false), isFalse);
      expect(
        policy.canModifyFiles(mode, planApproved: true),
        mode == ConversationMode.build,
      );
    }
  });
  testWidgets('guided creation saves selected choices and opens workspace', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = StudioStore(await SharedPreferences.getInstance());
    await tester.pumpWidget(StudioApp(store: store));
    await tester.tap(find.text('Let’s create something'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Show my options'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Tell me a little more'), findsOneWidget);
    await tester.enterText(
      find.byType(TextField).last,
      'A macOS task manager for daily work',
    );
    await tester.tap(find.text('Show my options'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Web app'));
    await tester.tap(find.text('Web app'));
    await tester.tap(find.text('Review project'));
    await tester.pumpAndSettle();
    expect(find.text('Platforms: Web'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, '');
    await tester.tap(find.text('Create project'));
    await tester.pumpAndSettle();
    expect(find.text('Enter a project name'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, 'Task manager');
    await tester.tap(find.text('Create project'));
    await tester.pumpAndSettle();
    expect(store.load().single.name, 'Task manager');
    expect(store.load().single.platforms, ['Web']);
    expect(store.load().single.description, contains('Task list'));
    expect(find.text('Apply instruction'), findsOneWidget);
    await tester.tap(find.byTooltip('Projects'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'missing');
    await tester.pumpAndSettle();
    expect(find.text('No matching projects'), findsOneWidget);
  });
  testWidgets('project conversation restores saved messages', (tester) async {
    SharedPreferences.setMockInitialValues({
      'studio.chat.v1.chat-test':
          '[{"role":"user","content":"Build a task planner"}]',
    });
    await tester.pumpWidget(
      const MaterialApp(
        home: ModelChat(
          project: StudioProject(
            id: 'chat-test',
            name: 'Planner',
            description: '',
            type: 'Flutter',
            platforms: ['macOS'],
            location: '',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Build a task planner'), findsOneWidget);
    expect(find.text('Discuss · Planner'), findsOneWidget);
  });
}
