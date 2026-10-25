import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/controllers/app_workspace_controller.dart';
import 'package:asg/models/generation_event.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/application_editor.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/views/project_workspace.dart';

const project = StudioProject(
  id: 'stream-test',
  name: 'Demo',
  description: 'A task planner',
  type: 'Flutter',
  platforms: ['Web'],
  location: '',
);

class ControlledProvider implements StreamingModelProvider {
  final events = StreamController<GenerationEvent>();
  bool cancelled = false;
  @override
  Stream<GenerationEvent> generateEvents(String prompt) => events.stream;
  @override
  Stream<String> generate(String prompt) async* {
    await for (final e in generateEvents(prompt)) {
      if (e.text.isNotEmpty) yield e.text;
    }
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    if (!events.isClosed) await events.close();
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  testWidgets(
    'chat shows thinking, streamed writing, then refreshed application',
    (tester) async {
      final store = ApplicationStore.fromPreferences(
        await SharedPreferences.getInstance(),
      );
      final provider = ControlledProvider();
      final controller = AppWorkspaceController(
        project,
        openStore: () async => store,
        editor: ApplicationEditor(
          allowBuiltInEdits: false,
          createProvider: (_) => provider,
        ),
      );
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectWorkspace(project: project, controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              w.decoration?.hintText?.startsWith('For example:') == true,
        ),
        'Apply my custom change',
      );
      await tester.tap(find.text('Apply instruction'));
      await tester.pump();
      expect(find.text('Thinking…'), findsWidgets);
      expect(find.byType(CircularProgressIndicator), findsWidgets);
      provider.events.add(const GenerationEvent.text('{"summary":"Changing '));
      await tester.pump();
      expect(find.text('Writing response…'), findsWidgets);
      final draft = tester.widget<SelectableText>(
        find.byKey(const ValueKey('streamingResponse')),
      );
      expect(draft.data, 'Changing ');
      expect(controller.revision, 1);
      provider.events.add(
        const GenerationEvent.text(
          'the title","edits":[{"op":"setTitle","value":"Live updated"}]}',
        ),
      );
      await tester.pump();
      expect(
        controller.revision,
        1,
        reason: 'Incomplete stream must not update the preview',
      );
      await provider.events.close();
      await tester.pumpAndSettle();
      expect(controller.revision, 2);
      expect(controller.definition!.title, 'Live updated');
      expect(find.text('Live · v2'), findsOneWidget);
      expect(find.byKey(const ValueKey('streamingResponse')), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
    },
  );
  test(
    'cancelled partial output cannot update or persist an application',
    () async {
      final store = ApplicationStore.fromPreferences(
        await SharedPreferences.getInstance(),
      );
      final provider = ControlledProvider();
      final controller = AppWorkspaceController(
        project,
        openStore: () async => store,
        editor: ApplicationEditor(
          allowBuiltInEdits: false,
          createProvider: (_) => provider,
        ),
      );
      await controller.load();
      final applying = controller.apply('Custom request');
      await Future<void>.delayed(Duration.zero);
      provider.events.add(const GenerationEvent.text('{"summary":"Partial'));
      await Future<void>.delayed(Duration.zero);
      controller.cancelGeneration();
      expect(await applying, false);
      expect(controller.revision, 1);
      expect(store.load(project).revision, 1);
      expect(controller.error, contains('cancelled'));
      expect(provider.cancelled, true);
      controller.dispose();
    },
  );
}
