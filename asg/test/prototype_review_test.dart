import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/models/conversation_mode.dart';
import 'package:asg/models/generation_event.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/prototype_review_evidence.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/views/model_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'dashboard_build_status_test.dart' as build;
import 'planning_conversation_test.dart'
    show project, ControlledRecords, PlanningProvider, tick, chat;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('evidence distinguishes fallback, saved, stale and corrupt records without writes', () async {
    final records = ControlledRecords();
    final evidence = PrototypeReviewEvidence(records);
    Map<String, dynamic> read() =>
        jsonDecode(evidence.load(project)) as Map<String, dynamic>;
    expect(read()['applicationStatus'], 'unsaved starter fallback');
    expect(read()['savedBuildState'], 'none');
    expect(records.writes, 0);
    await ApplicationStore(records)
        .save(project.id, const ApplicationSnapshot(build.definition, [], 7));
    await SourceGenerationStore(records)
        .save(project.id, build.outcome(project, SourceGenerationPhase.ready));
    final before = Map.of(records.values);
    expect(read()['applicationStatus'], 'saved prototype');
    expect(read()['revision'], 7);
    expect(read()['definition'], build.definition.toJson());
    expect(read()['savedBuildState'], 'passed');
    expect(read()['savedBuildInputMatch'], 'current');
    final changed = StudioProject(
      id: project.id,
      name: project.name,
      description: 'New requirements',
      type: project.type,
      platforms: project.platforms,
      location: project.location,
    );
    expect(
      jsonDecode(evidence.load(changed))['savedBuildInputMatch'],
      'outdated',
    );
    expect(records.values, before);
    expect(records.writes, 2);
    records.values['studio.application.v1.${project.id}'] = 'broken';
    expect(read()['applicationStatus'], startsWith('unreadable'));
    expect(read().containsKey('definition'), false);
    expect(read()['savedBuildState'], 'passed');
    expect(read()['savedBuildInputMatch'], 'unknown');
    records.values['studio.generation.v1.${project.id}'] = '{}';
    expect(read()['savedBuildState'], 'unavailable');
    expect(records.writes, 2);
  });

  test(
    'large definitions are omitted explicitly and never partially presented',
    () async {
      final records = ControlledRecords();
      final definition = AppDefinition(
        title: 'Large',
        theme: 'green',
        elements: [
          for (var i = 0; i < 5; i++)
            AppElement(id: 'text$i', kind: ElementKind.text, label: 'x' * 4000),
        ],
      );
      await ApplicationStore(records)
          .save(project.id, ApplicationSnapshot(definition, [], 2));
      final evidence = PrototypeReviewEvidence(records).load(project);
      final data = jsonDecode(evidence) as Map<String, dynamic>;
      expect(data['applicationStatus'], 'saved prototype');
      expect(
        data['definitionStatus'],
        contains('exceeds review context limit'),
      );
      expect(data.containsKey('definition'), false);
      expect(evidence.length, lessThan(1500));
      expect(records.writes, 1);
    },
  );

  test('review reads fresh evidence on every request and persists labeled reports only', () async {
    final records = ControlledRecords();
    var provider = PlanningProvider();
    final controller = ChatController(
      project,
      openStore: () async => ConversationStore(records),
      createProvider: (_) => provider,
    );
    addTearDown(controller.dispose);
    await controller.load();
    controller.selectMode(ConversationMode.review);
    var sending = controller.send('Does this implement weekly filtering?');
    await tick();
    expect(provider.prompt, contains('Requirement coverage'));
    expect(provider.prompt, contains('unsaved starter fallback'));
    expect(provider.prompt, contains('Track weekly tasks'));
    expect(provider.prompt, contains('no file or command tools'));
    controller.selectMode(ConversationMode.plan);
    expect(controller.mode, ConversationMode.review);
    provider.events.add(
      const GenerationEvent.text('Gaps: no weekly filter evidence.'),
    );
    await provider.events.close();
    await sending;
    expect(controller.error, isNull);
    expect(controller.messages.first.content, startsWith('[Review request]'));
    expect(
      controller.messages.last.content,
      ConversationMode.review.labelResponse('Gaps: no weekly filter evidence.'),
    );
    expect(records.values.keys, ['studio.chat.v1.planning']);
    await ApplicationStore(records)
        .save(project.id, const ApplicationSnapshot(build.definition, [], 8));
    final application = records.values['studio.application.v1.planning'];
    provider = PlanningProvider();
    sending = controller.send('Review again');
    await tick();
    expect(provider.prompt, contains('"revision":8'));
    expect(provider.prompt, contains('"title":"App"'));
    provider.events.add(const GenerationEvent.text('Updated advisory report'));
    await provider.events.close();
    await sending;
    expect(records.values['studio.application.v1.planning'], application);
    final reopened = chat(records, PlanningProvider());
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.mode, ConversationMode.discuss);
    expect(reopened.messages.last.content, controller.messages.last.content);
  });

  testWidgets(
    'Review selector and advisory report work with keyboard and enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      tester.view.viewInsets = const FakeViewPadding(bottom: 250);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetViewInsets);
      final provider = PlanningProvider();
      final controller = chat(ControlledRecords(), provider);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: ModelChat(project: project, controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review'));
      await tester.tap(find.text('Review'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('No source inspection or new checks'),
        findsOneWidget,
      );
      await tester.ensureVisible(find.byType(TextField));
      await tester.enterText(find.byType(TextField), 'Review requirements');
      await tester.ensureVisible(find.byTooltip('Send'));
      await tester.tap(find.byTooltip('Send'));
      await tester.pump();
      provider.events.add(
        const GenerationEvent.text('Requirement coverage: incomplete'),
      );
      await provider.events.close();
      await tester.pumpAndSettle();
      expect(find.textContaining('[Advisory prototype review'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  test(
    'real Qwen review streams an advisory report from supplied prototype',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      addTearDown(() => HttpOverrides.global = previous);
      final records = ControlledRecords();
      await ApplicationStore(records)
          .save(project.id, const ApplicationSnapshot(build.definition, [], 3));
      final before = records.values['studio.application.v1.planning'];
      final controller = ChatController(
        project,
        openStore: () async => ConversationStore(records),
      );
      addTearDown(controller.dispose);
      await controller.load();
      controller.selectMode(ConversationMode.review);
      final drafts = <String>{};
      controller.addListener(() {
        if (controller.draftResponse.isNotEmpty) {
          drafts.add(controller.draftResponse);
        }
      });
      expect(
        await controller.send(
          'Briefly review whether the supplied counter prototype satisfies weekly task tracking. Use one short line per section.',
        ),
        true,
      );
      expect(controller.error, isNull);
      expect(drafts.length, greaterThan(1));
      final report = controller.messages.last.content;
      expect(report, startsWith('[Advisory prototype review'));
      expect(report.toLowerCase(), contains('counter'));
      expect(report.toLowerCase(), contains('task'));
      expect(ConversationStore(records).load(project.id).last.content, report);
      expect(records.values['studio.application.v1.planning'], before);
    },
    skip: !const bool.fromEnvironment('ASG_REAL_INFERENCE'),
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
