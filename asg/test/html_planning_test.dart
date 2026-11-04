// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:sembast/sembast_io.dart';
import 'package:asg/services/studio_database.dart';

import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/generation_event.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/models/html/saved_html_starter.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/html/html_starter_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/plan_task_import.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/html_project_workspace.dart';
import 'package:asg/views/model_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'planning_conversation_test.dart'
    show ControlledRecords, PlanningProvider, tick;

const project = StudioProject(
  id: 'html-plan',
  name: 'Site',
  description: 'A local site',
  type: 'HTML',
  platforms: ['Web'],
  location: '/tmp/html-plan',
);
const proposal =
    '```asg-tasks\n{"version":1,"tasks":[{"id":"T1","requirementId":"R1","title":"Add navigation","dependencies":[]}]}\n```';

Future<ControlledRecords> seed() async {
  final records = ControlledRecords();
  await StudioStore(records).save([project]);
  await records.setString(
    HtmlStarterStore.key,
    jsonEncode([
      SavedHtmlStarter(
        directory: project.location,
        input: HtmlSiteInput(title: 'Site', description: 'Original'),
      ).toJson(),
    ]),
  );
  final store = RequirementsStore(records);
  await store.save(
    project.id,
    store.load(project.id),
    RequirementsBoard(
      requirements: [
        ProjectRequirement(
          id: 'R1',
          title: 'Navigation',
          acceptance: 'Keyboard accessible links',
        ),
      ],
    ),
  );
  // A corrupt Flutter record must never be read for an HTML Plan.
  records.values['studio.application.v1.${project.id}'] =
      'unreadable Flutter data';
  return records;
}

ChatController chat(ControlledRecords records, PlanningProvider provider) =>
    ChatController(
      project,
      openStore: () async => ConversationStore(records),
      createProvider: (_) => provider,
    );

Future<void> draft(ChatController controller, PlanningProvider provider) async {
  controller.selectMode(ConversationMode.plan);
  final request = controller.send('Plan navigation for this HTML site');
  await tick();
  provider.events.add(const GenerationEvent.text(proposal));
  await provider.events.close();
  expect(await request, true);
  expect(controller.error, isNull);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('HTML planning saves/reopens and imports scoped tasks without Flutter approval', () async {
    final records = await seed();
    final provider = PlanningProvider();
    final controller = chat(records, provider);
    addTearDown(controller.dispose);
    await controller.load();
    await draft(controller, provider);
    expect(provider.prompt, contains('HTML/CSS/JavaScript'));
    expect(provider.prompt, contains('R1: Navigation'));
    expect(
      provider.prompt,
      isNot(contains('The only executable adapter creates the fixed Flutter')),
    );
    final context = jsonDecode(controller.latestPlan!.planContext!) as Map;
    expect(context['htmlStarter'], isNotNull);
    expect(context.containsKey('prototypeDefinition'), false);
    expect(controller.canApprovePlan, false);
    expect(controller.planApproved, false);
    await controller.setPlanApproval(true);
    expect(records.getString('studio.planApproval.v1.${project.id}'), isNull);
    expect(
      () => PlanApprovalStore(records).requireCurrentApproval(project),
      throwsStateError,
    );
    await expectLater(
      PlanApprovalStore(records).save(project, controller.messages, true),
      throwsUnsupportedError,
    );
    expect(controller.canAddPlanTasks, true);
    await controller.addPlanTasks();
    expect(RequirementsStore(records).load(project.id).tasks.single.id, 'T1');
    expect(controller.canAddPlanTasks, false);
    final reopened = chat(records, PlanningProvider());
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.latestPlan!.content, contains(proposal));
    expect(reopened.canAddPlanTasks, false);
    reopened.selectMode(ConversationMode.review);
    expect(reopened.mode, ConversationMode.discuss);
    expect(
      records.values['studio.application.v1.${project.id}'],
      'unreadable Flutter data',
    );
    expect(
      records.values.keys.any(
        (k) => k.contains('sourceGeneration') || k.contains('buildJournal'),
      ),
      false,
    );
  });

  test('HTML Plan and imported tasks survive native database reopen', () async {
    final seedRecords = await seed();
    final dir = await Directory.systemTemp.createTemp('asg-html-plan-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/records.db';
    final prefs = await SharedPreferences.getInstance();
    final native = await databaseFactoryIo.openDatabase(path);
    final db = await StudioDatabase.migrate(native, prefs);
    for (final entry in seedRecords.values.entries) {
      if (entry.key.startsWith('studio.application.')) continue;
      await db.setString(entry.key, entry.value);
    }
    final provider = PlanningProvider();
    final active = ChatController(
      project,
      openStore: () async => ConversationStore(db),
      createProvider: (_) => provider,
    );
    await active.load();
    await draft(active, provider);
    await active.addPlanTasks();
    final saved = active.messages;
    active.dispose();
    await native.close();
    final reopenedNative = await databaseFactoryIo.openDatabase(path);
    addTearDown(reopenedNative.close);
    final reopened = await StudioDatabase.migrate(reopenedNative, prefs);
    expect(
      ConversationStore(reopened).load(project.id).last.content,
      saved.last.content,
    );
    expect(RequirementsStore(reopened).load(project.id).tasks.single.id, 'T1');
    expect(RequirementsStore(reopened).load('other-project').tasks, isEmpty);
    await expectLater(
      PlanTaskImport(reopened).add(project, saved),
      throwsStateError,
    );
    expect(reopened.getString('studio.application.v1.${project.id}'), isNull);
  });

  for (final change in ['board', 'starter', 'project', 'corruptStarter']) {
    test(
      'HTML task import refuses changed $change and preserves records',
      () async {
        final records = await seed();
        final provider = PlanningProvider();
        final active = chat(records, provider);
        addTearDown(active.dispose);
        await active.load();
        await draft(active, provider);
        switch (change) {
          case 'board':
            final store = RequirementsStore(records);
            await store.save(
              project.id,
              store.load(project.id),
              RequirementsBoard(
                requirements: [
                  ProjectRequirement(
                    id: 'R2',
                    title: 'Changed',
                    acceptance: 'Changed',
                  ),
                ],
              ),
            );
          case 'starter':
            records.values[HtmlStarterStore.key] = jsonEncode([
              SavedHtmlStarter(
                directory: project.location,
                input: HtmlSiteInput(
                  title: 'Changed',
                  description: 'Different',
                ),
              ).toJson(),
            ]);
          case 'project':
            records.values['studio.projects.v1'] = '[]';
          case 'corruptStarter':
            records.values[HtmlStarterStore.key] = 'bad';
        }
        final before = Map.of(records.values);
        expect(active.canAddPlanTasks, false);
        await expectLater(
          PlanTaskImport(records).add(project, active.messages),
          throwsA(anything),
        );
        expect(records.values, before);
      },
    );
  }

  test('failed HTML task import retries without asking model again', () async {
    final records = await seed();
    final provider = PlanningProvider();
    final controller = chat(records, provider);
    addTearDown(controller.dispose);
    await controller.load();
    await draft(controller, provider);
    records.failWrite = records.writes + 1;
    await controller.addPlanTasks();
    expect(controller.error, isNotNull);
    expect(RequirementsStore(records).load(project.id).tasks, isEmpty);
    records.failWrite = null;
    await controller.addPlanTasks();
    expect(RequirementsStore(records).load(project.id).tasks.single.id, 'T1');
  });

  for (final narrow in [false, true]) {
    testWidgets('HTML advisory UI and entry route narrow=$narrow', (
      tester,
    ) async {
      tester.view.physicalSize = Size(narrow ? 320 : 1200, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = await seed();
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(narrow ? 2 : 1)),
            child: child!,
          ),
          home: HtmlProjectWorkspace(project: project, records: records),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Discuss and plan HTML'),
        220,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Discuss and plan HTML'));
      await tester.pumpAndSettle();
      expect(find.byType(ModelChat), findsOneWidget);
      expect(find.text('Review'), findsNothing);
      await tester.ensureVisible(find.text('Plan'));
      await tester.tap(find.text('Plan'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(
          'No current plan approval. Only newly saved Plan drafts can be approved.',
        ),
        160,
        scrollable: find
            .byWidgetPredicate(
              (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
            )
            .first,
      );
      expect(
        find.text(
          'No current plan approval. Only newly saved Plan drafts can be approved.',
        ),
        findsOneWidget,
      );
      expect(find.text('Approve latest saved plan'), findsNothing);
      expect(tester.takeException(), isNull);
      expect(ConversationStore(records).load(project.id), isEmpty);
    });
  }
}
