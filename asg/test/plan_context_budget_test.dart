import 'dart:convert';

import 'package:asg/models/chat_message.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/generation_event.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/model_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'plan_approval_test.dart' show planned;
import 'planning_conversation_test.dart'
    show ControlledRecords, PlanningProvider, chat, project, tick;

// Include a final requirement and dependent task to detect lost tail content.
RequirementsBoard boardOfLength(int length) {
  RequirementsBoard make(int padding) => RequirementsBoard(
    requirements: [
      for (var i = 0; i < 8; i++)
        ProjectRequirement(
          id: 'R$i',
          title: 'Requirement $i',
          acceptance: 'a' * (1 + (padding ~/ 8) + (i < padding % 8 ? 1 : 0)),
        ),
    ],
    tasks: [
      DevelopmentTask(id: 'TailTask', requirementId: 'R7', title: 'Tail'),
    ],
  );
  final board = make(length - make(0).document(project.name).length);
  board.validate();
  expect(board.document(project.name).length, length);
  return board;
}

Future<void> saveBoard(ControlledRecords records, int length) async {
  final store = RequirementsStore(records);
  await store.save(project.id, store.load(project.id), boardOfLength(length));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('oversized Plan preserves durable history/approval and never creates provider', () async {
    final records = ControlledRecords();
    final previous = await planned(records);
    await previous.setPlanApproval(true);
    previous.dispose();
    await saveBoard(records, 12001);
    final before = Map<String, String>.of(records.values);
    final writes = records.writes;
    var creations = 0;
    final controller = ChatController(
      project,
      openStore: () async => ConversationStore(records),
      createProvider: (_) {
        creations++;
        return PlanningProvider();
      },
    );
    addTearDown(controller.dispose);
    await controller.load();
    controller.selectMode(ConversationMode.plan);
    expect(await controller.send('Keep my request'), false);
    expect(creations, 0);
    expect(records.writes, writes);
    expect(records.values, before);
    expect(controller.messages, hasLength(2));
    expect(controller.error, contains('12001 characters'));
    expect(controller.error, contains('Shorten'));
    expect(controller.busy, false);
    expect(controller.hasUnsavedResponse, false);
    expect(controller.canApprovePlan, false);
  });

  test('legacy oversized draft cannot be approved or execute; withdrawal works', () async {
    final records = ControlledRecords();
    final controller = await planned(records);
    addTearDown(controller.dispose);
    await controller.setPlanApproval(true);
    await saveBoard(records, 12001);
    // Simulate a draft/approval created by the previous truncating application.
    final approvals = PlanApprovalStore(records);
    final approval = approvals.load(project.id)!;
    final context = jsonDecode(approval.context) as Map<String, dynamic>;
    context['requirementsRevision'] = RequirementsStore(records)
        .load(project.id)
        .revision;
    final legacyContext = jsonEncode(context);
    final messages = ConversationStore(records).load(project.id);
    messages[messages.length - 1] = ChatMessage(
      role: 'assistant',
      content: messages.last.content,
      planContext: legacyContext,
    );
    await ConversationStore(records).save(project.id, messages);
    final raw = approval.toJson()..['context'] = legacyContext;
    records.values['studio.planApproval.v1.${project.id}'] = jsonEncode(raw);
    final before = Map<String, String>.of(records.values);
    expect(() => approvals.requireCurrentApproval(project), throwsStateError);
    await expectLater(
      approvals.save(project, messages, true),
      throwsStateError,
    );
    expect(records.values, before);
    await approvals.save(project, messages, false);
    expect(approvals.load(project.id)!.approved, false);
  });

  test(
    'exact budget sends full board and retry after shortening succeeds',
    () async {
      final records = ControlledRecords();
      await saveBoard(records, 12001);
      await StudioStore(records).save([project]);
      final provider = PlanningProvider();
      final controller = chat(records, provider);
      addTearDown(controller.dispose);
      await controller.load();
      controller.selectMode(ConversationMode.plan);
      expect(await controller.send('Plan'), false);
      await saveBoard(records, 12000);
      final full = RequirementsStore(records)
          .load(project.id)
          .document(project.name);
      final sending = controller.send('Plan');
      await tick();
      expect(provider.prompt, contains(full));
      expect(provider.prompt, contains('TailTask: Tail'));
      expect(provider.prompt, isNot(contains('context truncated')));
      provider.events.add(const GenerationEvent.text('Complete board draft'));
      await provider.events.close();
      expect(await sending, true);
      expect(controller.error, isNull);
      expect(controller.messages.last.planContext, isNotNull);
      expect(controller.canApprovePlan, true);
      await controller.setPlanApproval(true);
      expect(controller.planApproved, true);
      await saveBoard(records, 11999);
      expect(controller.planApproved, false);
    },
  );

  test(
    'Discuss and Review retain labeled bounded context on a large board',
    () async {
      for (final mode in [ConversationMode.discuss, ConversationMode.review]) {
        final records = ControlledRecords();
        await saveBoard(records, 13000);
        final provider = PlanningProvider();
        final controller = chat(records, provider);
        await controller.load();
        controller.selectMode(mode);
        final sending = controller.send('Advise');
        await tick();
        expect(provider.prompt, contains('[Requirements context truncated;'));
        expect(provider.prompt, isNot(contains('TailTask: Tail')));
        provider.events.add(const GenerationEvent.text('Advisory answer'));
        await provider.events.close();
        expect(await sending, true);
        expect(controller.error, isNull);
        expect(controller.messages.last.planContext, isNull);
        controller.dispose();
      }
    },
  );

  testWidgets(
    'oversized Plan error retains request on narrow enlarged-text UI',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = ControlledRecords();
      await saveBoard(records, 12001);
      final provider = PlanningProvider();
      final controller = chat(records, provider);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: ModelChat(project: project, controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Plan'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Keep this request');
      await tester.ensureVisible(find.byTooltip('Send'));
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Keep this request',
      );
      await tester.ensureVisible(find.textContaining('12001 characters'));
      expect(find.textContaining('12001 characters'), findsOneWidget);
      expect(provider.prompt, isNull);
      expect(tester.takeException(), isNull);
    },
  );
}
