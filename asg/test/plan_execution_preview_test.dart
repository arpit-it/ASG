import 'board_mapped_build_plan_test.dart' show mappedBoard, boardContent;

import 'package:asg/models/build_plan.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/model_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'planning_conversation_test.dart'
    show ControlledRecords, project, chat, PlanningProvider;

Future<void> seed(ControlledRecords records, String content) async {
  await StudioStore(records).save([project]);
  await ConversationStore(records).save(project.id, [
    ChatMessage(
      role: 'assistant',
      content: content,
      planContext: PlanApprovalStore(records).contextFor(project),
    ),
  ]);
}

void main() {
  test('board mapping preview rereads durable references without marking completion', () async {
    final records = ControlledRecords();
    final boards = RequirementsStore(records);
    await boards.save(project.id, boards.load(project.id), mappedBoard());
    await seed(records, boardContent());
    final controller = chat(records, PlanningProvider());
    addTearDown(controller.dispose);
    await controller.load();
    final writes = records.writes;
    expect(controller.executionPlanPreview, contains('board task: Ttest'));
    expect(records.writes, writes);
    expect(
      boards.load(project.id).tasks.every((t) => t.status == TaskStatus.queued),
      isTrue,
    );
    final original = boards.load(project.id);
    await boards.save(
      project.id,
      original,
      RequirementsBoard(requirements: original.requirements),
    );
    expect(controller.executionPlanPreview, contains('outdated'));
    await seed(records, boardContent());
    final fresh = chat(records, PlanningProvider());
    addTearDown(fresh.dispose);
    await fresh.load();
    expect(
      fresh.executionPlanPreview,
      contains('A mapped board task is missing.'),
    );
  });

  test('preview validates saved tasks without approving or writing', () async {
    final records = ControlledRecords();
    await seed(records, BuildPlan.starterContract);
    final controller = chat(records, PlanningProvider());
    addTearDown(controller.dispose);
    await controller.load();
    final writes = records.writes;
    final preview = controller.executionPlanPreview;
    expect(
      preview,
      contains('starter-resolve: Resolve dependencies; depends on: none'),
    );
    expect(
      preview,
      contains('starter-analyze: Analyze source; depends on: starter-resolve'),
    );
    expect(
      preview,
      contains('starter-test: Run tests; depends on: starter-analyze'),
    );
    expect(
      preview,
      contains(
        'starter-build: Build Flutter web output; depends on: starter-test',
      ),
    );
    expect(preview, contains('not execution results'));
    expect(preview, contains('separate operation consent'));
    expect(records.writes, writes);
    expect(controller.planApproved, false);
    expect(PlanApprovalStore(records).load(project.id), isNull);
  });

  test(
    'advisory and malformed contracts never advertise validated tasks',
    () async {
      for (final content in [
        'Ordinary prose',
        '```asg-tasks\n{"version":1,"tasks":[]}\n```',
        BuildPlan.starterContract.replaceFirst('flutter-starter', 'shell'),
        '${BuildPlan.starterContract}\n${BuildPlan.starterContract}',
      ]) {
        final records = ControlledRecords();
        await seed(records, content);
        final controller = chat(records, PlanningProvider());
        await controller.load();
        expect(
          controller.executionPlanPreview,
          isNot(contains('Validated fixed')),
        );
        expect(
          controller.canApprovePlan,
          true,
        ); // Advisory approval is preserved.
        await controller.setPlanApproval(true);
        expect(controller.planApproved, true);
        expect(
          controller.executionPlanPreview,
          isNot(contains('Validated fixed')),
        );
        controller.dispose();
      }
    },
  );

  test(
    'preview rejects changed durable evidence and pending response',
    () async {
      for (final mode in ['board', 'plan', 'project', 'corrupt']) {
        final records = ControlledRecords();
        await seed(records, BuildPlan.starterContract);
        final controller = chat(records, PlanningProvider());
        await controller.load();
        switch (mode) {
          case 'board':
            await RequirementsStore(records)
                .save(project.id, RequirementsBoard(), RequirementsBoard());
          case 'plan':
            await seed(records, '${BuildPlan.starterContract}\nReplacement');
          case 'project':
            await StudioStore(records).save([]);
          case 'corrupt':
            records.values['studio.chat.v1.${project.id}'] = 'broken';
        }
        final writes = records.writes;
        expect(
          controller.executionPlanPreview,
          isNot(contains('Validated fixed')),
        );
        expect(records.writes, writes);
        controller.busy = true;
        expect(controller.executionPlanPreview, contains('Wait until'));
        controller.dispose();
        expect(controller.executionPlanPreview, contains('unavailable'));
      }
    },
  );

  testWidgets('validated tasks and approval scroll at narrow enlarged layout', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = ControlledRecords();
    await seed(records, BuildPlan.starterContract);
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
    expect(
      find.textContaining('starter-build: Build Flutter web output'),
      findsOneWidget,
    );
    final approval = find.text('Approve latest saved plan');
    await tester.scrollUntilVisible(
      approval,
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(approval);
    await tester.pumpAndSettle();
    expect(controller.planApproved, true);
    expect(tester.takeException(), isNull);
  });
}
