import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/plan_task_proposal.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/plan_task_import.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/model_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'planning_conversation_test.dart'
    show ControlledRecords, project, chat, PlanningProvider;

const r = ProjectRequirement(
  id: 'R1',
  title: 'List',
  acceptance: 'Save a list',
);
Map<String, Object> task(String id, List<String> deps) => {
  'id': id,
  'requirementId': 'R1',
  'title': 'Implement $id',
  'dependencies': deps,
};
String proposal(List<Object> tasks) =>
    '```asg-tasks\n${jsonEncode({'version': 1, 'tasks': tasks})}\n```';
String get valid => proposal([
  task('T1', ['Existing']),
  task('T2', ['T1']),
]);
Future<List<ChatMessage>> seed(RecordStorage records) async {
  await StudioStore(records).save([project]);
  final store = RequirementsStore(records);
  await store.save(
    project.id,
    store.load(project.id),
    RequirementsBoard(
      requirements: [r],
      tasks: [
        DevelopmentTask(
          id: 'Existing',
          requirementId: 'R1',
          title: 'Existing work',
          status: TaskStatus.done,
        ),
      ],
    ),
  );
  final messages = [
    ChatMessage(
      role: 'assistant',
      content: valid,
      planContext: PlanApprovalStore(records).contextFor(project),
    ),
  ];
  await ConversationStore(records).save(project.id, messages);
  return messages;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'additive graph rejects collisions references cycles and model completion',
    () {
      final current = RequirementsBoard(
        requirements: [r],
        tasks: [
          DevelopmentTask(
            id: 'Existing',
            requirementId: 'R1',
            title: 'Existing work',
          ),
        ],
      );
      final parsed = PlanTaskProposal.parse(valid);
      expect(parsed.addTo(current).tasks.length, 3);
      expect(() => parsed.tasks.clear(), throwsUnsupportedError);
      for (final tasks in [
        [task('Existing', [])],
        [
          task('T1', ['Missing']),
        ],
        [
          task('T1', ['T2']),
          task('T2', ['T1']),
        ],
        [task('T1', []), task('T1', [])],
        [
          {...task('T1', []), 'requirementId': 'Unknown'},
        ],
        [
          {...task('T1', []), 'title': ''},
        ],
      ]) {
        expect(
          () => PlanTaskProposal.parse(proposal(tasks)).addTo(current),
          throwsFormatException,
        );
      }
      for (final content in [
        'ordinary prose',
        '$valid\n$valid',
        '```asg-tasks\n{}\n```',
        '${'x' * 65536}$valid',
        proposal([]),
        proposal([
          {...task('T1', []), 'status': 'done'},
        ]),
        proposal([
          {...task('T1', []), 'command': 'shell'},
        ]),
        valid.replaceFirst('"version":1', '"version":2,"version":1'),
        valid.replaceFirst('"id":"T1"', r'"id":"T1","\u0069d":"T1"'),
        valid.replaceFirst('"dependencies":["Existing"]', '"dependencies":[1]'),
      ]) {
        expect(() => PlanTaskProposal.parse(content), throwsFormatException);
      }
    },
  );
  test('import persists queued tasks and invalidates approval after actual database reopen', () async {
    final dir = await Directory.systemTemp.createTemp('asg-plan-tasks-');
    addTearDown(() => dir.delete(recursive: true));
    final path = '${dir.path}/records.db';
    final native = await databaseFactoryIo.openDatabase(path);
    final prefs = await SharedPreferences.getInstance();
    final db = await StudioDatabase.migrate(native, prefs);
    final messages = await seed(db);
    await PlanApprovalStore(db).save(project, messages, true);
    final importer = PlanTaskImport(db);
    final before = RequirementsStore(db).load(project.id);
    expect(
      importer.preview(project, messages).preview,
      contains('T2: Implement T2'),
    );
    expect(RequirementsStore(db).load(project.id).revision, before.revision);
    await importer.add(project, messages);
    expect(
      () => PlanApprovalStore(db).requireCurrentApproval(project),
      throwsStateError,
    );
    await native.close();
    final reopenedNative = await databaseFactoryIo.openDatabase(path);
    addTearDown(reopenedNative.close);
    final reopened = await StudioDatabase.migrate(reopenedNative, prefs);
    final saved = RequirementsStore(reopened).load(project.id);
    expect(saved.revision, before.revision + 1);
    expect(saved.requirements.single.toJson(), r.toJson());
    expect(saved.tasks.first.status, TaskStatus.done);
    expect(saved.tasks.skip(1).map((t) => t.status), [
      TaskStatus.queued,
      TaskStatus.queued,
    ]);
    expect(saved.tasks.last.dependencies, ['T1']);
    await expectLater(
      PlanTaskImport(reopened).add(project, messages),
      throwsStateError,
    );
    expect(
      RequirementsStore(reopened).load(project.id).revision,
      saved.revision,
    );
  });
  test('stale replaced legacy corrupt or missing project evidence cannot overwrite', () async {
    for (final mode in ['board', 'plan', 'legacy', 'project', 'corrupt']) {
      final records = ControlledRecords();
      final messages = await seed(records);
      switch (mode) {
        case 'board':
          final store = RequirementsStore(records);
          final current = store.load(project.id);
          await store.save(project.id, current, current);
        case 'plan':
          await ConversationStore(records).save(project.id, [
            ChatMessage(
              role: 'assistant',
              content: '$valid\nReplaced',
              planContext: messages.single.planContext,
            ),
          ]);
        case 'legacy':
          await ConversationStore(
            records,
          ).save(project.id, [ChatMessage(role: 'assistant', content: valid)]);
        case 'project':
          await StudioStore(records).save([]);
        case 'corrupt':
          records.values[RequirementsStore.key(project.id)] = 'broken';
      }
      final before = Map.of(records.values);
      await expectLater(
        PlanTaskImport(records).add(project, messages),
        throwsA(anything),
      );
      expect(records.values, before);
    }
  });
  test(
    'controller retries save without inference and guards overlap and disposal',
    () async {
      final records = ControlledRecords();
      await seed(records);
      final provider = PlanningProvider();
      final controller = chat(records, provider);
      await controller.load();
      controller.selectMode(ConversationMode.plan);
      expect(controller.canAddPlanTasks, true);
      final original = records.values[RequirementsStore.key(project.id)];
      records.failWrite = records.writes + 1;
      await controller.addPlanTasks();
      expect(controller.error, contains('could not be saved'));
      expect(controller.canAddPlanTasks, true);
      expect(records.values[RequirementsStore.key(project.id)], original);
      records.gate = Completer<void>();
      final saving = controller.addPlanTasks();
      expect(controller.busy, true);
      final writes = records.writes;
      await controller.addPlanTasks();
      expect(await controller.send('No inference'), false);
      controller.selectMode(ConversationMode.review);
      expect(controller.mode, ConversationMode.plan);
      expect(records.writes, writes);
      controller.dispose();
      records.gate!.complete();
      await saving;
      expect(provider.prompt, isNull);
      expect(RequirementsStore(records).load(project.id).tasks.length, 3);
    },
  );
  testWidgets(
    'Plan previews tasks before explicit add and shows outdated approval',
    (tester) async {
      tester.view.physicalSize = const Size(900, 1500);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = ControlledRecords();
      final messages = await seed(records);
      await PlanApprovalStore(records).save(project, messages, true);
      final controller = ChatController(
        project,
        openStore: () async => ConversationStore(records),
      );
      controller.selectMode(ConversationMode.plan);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: ModelChat(project: project, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('T2: Implement T2 [R1]'), findsOneWidget);
      expect(RequirementsStore(records).load(project.id).tasks.length, 1);
      await tester.tap(find.text('Add proposed tasks to board'));
      await tester.pumpAndSettle();
      expect(RequirementsStore(records).load(project.id).tasks.length, 3);
      expect(
        find.text('Earlier approval is outdated. Review a current draft.'),
        findsOneWidget,
      );
      expect(controller.canAddPlanTasks, false);
      expect(controller.planApproved, false);
    },
  );
  testWidgets(
    'task preview and add action scroll at narrow width and enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = ControlledRecords();
      await seed(records);
      final controller = chat(records, PlanningProvider());
      controller.selectMode(ConversationMode.plan);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.8)),
            child: child!,
          ),
          home: Scaffold(
            body: ModelChat(project: project, controller: controller),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.text('Add proposed tasks to board');
      await tester.scrollUntilVisible(
        button,
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(RequirementsStore(records).load(project.id).tasks.length, 3);
      expect(tester.takeException(), isNull);
    },
  );
}
