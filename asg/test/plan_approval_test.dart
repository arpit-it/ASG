import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/generation_event.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/model_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'planning_conversation_test.dart'
    show project, ControlledRecords, PlanningProvider, chat, tick;

Future<ChatController> planned(ControlledRecords records) async {
  await StudioStore(records).save([project]);
  final provider = PlanningProvider();
  final controller = chat(records, provider);
  await controller.load();
  controller.selectMode(ConversationMode.plan);
  final sending = controller.send('Plan weekly tasks');
  await tick();
  provider.events.add(
    const GenerationEvent.text(
      'Requirements: weekly tasks. Acceptance: add a task.',
    ),
  );
  await provider.events.close();
  await sending;
  return controller;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'only app-marked saved Plan replies qualify; legacy JSON round trips',
    () async {
      final records = ControlledRecords();
      final legacy = const ChatMessage(
        role: 'assistant',
        content: '[Plan draft — not approved]\nSpoofed by text',
      );
      expect(ChatMessage.fromJson(legacy.toJson()).planContext, isNull);
      await ConversationStore(records).save(project.id, [legacy]);
      final controller = chat(records, PlanningProvider());
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.canApprovePlan, false);
      await controller.setPlanApproval(true);
      expect(records.values.keys, ['studio.chat.v1.planning']);
    },
  );

  test('approval waits for persistence; failed approval/withdraw can retry; no overlap', () async {
    final records = ControlledRecords();
    final controller = await planned(records);
    addTearDown(controller.dispose);
    expect(controller.canApprovePlan, true);
    records.failWrite = records.writes + 1;
    await controller.setPlanApproval(true);
    expect(controller.planApproved, false);
    expect(controller.error, contains('could not be saved'));
    records.gate = Completer<void>();
    final saving = controller.setPlanApproval(true);
    final writes = records.writes;
    expect(controller.planApproved, false);
    expect(controller.busy, true);
    await controller.setPlanApproval(true);
    expect(await controller.send('Do not infer'), false);
    controller.selectMode(ConversationMode.review);
    expect(controller.mode, ConversationMode.plan);
    controller.cancelGeneration();
    expect(controller.cancelled, false);
    expect(records.writes, writes);
    records.gate!.complete();
    await saving;
    expect(controller.planApproved, true);
    records.gate = null;
    records.failWrite = records.writes + 1;
    await controller.setPlanApproval(false);
    expect(controller.planApproved, true);
    await controller.setPlanApproval(false);
    expect(controller.planApproved, false);
    expect(PlanApprovalStore(records).load(project.id)!.approved, false);
    expect(records.values.keys.toSet(), {
      'studio.projects.v1',
      'studio.chat.v1.planning',
      'studio.planApproval.v1.planning',
    });
  });

  test('approval survives native database reopen and updated requirements become outdated', () async {
    final temp = await Directory.systemTemp.createTemp('asg-approval-');
    addTearDown(() => temp.delete(recursive: true));
    final records = ControlledRecords();
    final controller = await planned(records);
    addTearDown(controller.dispose);
    await controller.setPlanApproval(true);
    final prefs = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${temp.path}/studio.db');
    var storage = await StudioDatabase.migrate(db, prefs);
    for (final entry in records.values.entries) {
      await storage.setString(entry.key, entry.value);
    }
    await db.close();
    db = await databaseFactoryIo.openDatabase('${temp.path}/studio.db');
    addTearDown(db.close);
    storage = await StudioDatabase.migrate(db, prefs);
    final reopened = ChatController(
      project,
      openStore: () async => ConversationStore(storage),
    );
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.planApproved, true);
    final changed = StudioProject(
      id: project.id,
      name: project.name,
      description: 'Different requirements',
      type: project.type,
      platforms: project.platforms,
      location: project.location,
    );
    await StudioStore(storage).save([changed]);
    final updated = ChatController(
      changed,
      openStore: () async => ConversationStore(storage),
    );
    addTearDown(updated.dispose);
    await updated.load();
    expect(updated.planApproved, false);
    expect(updated.outdatedApproval, true);
    expect(updated.canApprovePlan, false);
    await updated.setPlanApproval(false);
    expect(updated.hasApproval, false);
    expect(updated.error, isNull);
  });

  test(
    'native reopen isolates corrupt approval and preserves raw evidence',
    () async {
      final temp = await Directory.systemTemp.createTemp(
        'asg-approval-damaged-',
      );
      addTearDown(() => temp.delete(recursive: true));
      final prefs = await SharedPreferences.getInstance();
      var db = await databaseFactoryIo.openDatabase('${temp.path}/studio.db');
      await StudioDatabase.migrate(db, prefs);
      final raw = StoreRef<String, String>('records');
      const key = 'studio.planApproval.v1.planning';
      await raw.record(key).put(db, 'damaged approval');
      await db.close();
      db = await databaseFactoryIo.openDatabase('${temp.path}/studio.db');
      addTearDown(db.close);
      final storage = await StudioDatabase.migrate(db, prefs);
      final controller = ChatController(
        project,
        openStore: () async => ConversationStore(storage),
      );
      addTearDown(controller.dispose);
      await controller.load();
      expect(controller.ready, true);
      expect(controller.approvalError, isNotNull);
      expect(controller.canApprovePlan, false);
      await controller.setPlanApproval(true);
      expect(await raw.record(key).get(db), 'damaged approval');
    },
  );

  test('new plan invalidates old consent; stale controller cannot approve changed durable draft', () async {
    final records = ControlledRecords();
    final controller = await planned(records);
    addTearDown(controller.dispose);
    await controller.setPlanApproval(true);
    final provider = PlanningProvider();
    final newer = chat(records, provider);
    addTearDown(newer.dispose);
    await newer.load();
    newer.selectMode(ConversationMode.plan);
    final sending = newer.send('Revise plan');
    await tick();
    provider.events.add(const GenerationEvent.text('New exact plan'));
    await provider.events.close();
    await sending;
    expect(newer.outdatedApproval, true);
    expect(newer.canApprovePlan, true);
    // An old screen cannot overwrite consent using its stale message list.
    await controller.setPlanApproval(false);
    expect(controller.error, contains('changed'));
    await newer.setPlanApproval(true);
    expect(newer.planApproved, true);
    expect(
      PlanApprovalStore(records).load(project.id)!.content,
      contains('New exact plan'),
    );
  });

  test(
    'changed or missing project is rejected and corrupt evidence is preserved',
    () async {
      final records = ControlledRecords();
      final controller = await planned(records);
      addTearDown(controller.dispose);
      await StudioStore(records).save([]);
      await controller.setPlanApproval(true);
      expect(controller.error, contains('missing'));
      await StudioStore(records).save([project, project]);
      await controller.setPlanApproval(true);
      expect(controller.error, contains('ambiguous'));
      records.values['studio.planApproval.v1.planning'] = '{bad';
      await controller.load();
      expect(controller.approvalError, isNotNull);
      expect(controller.ready, true);
      final writes = records.writes;
      await controller.setPlanApproval(true);
      expect(records.writes, writes);
      expect(records.values['studio.planApproval.v1.planning'], '{bad');
      expect(
        () => StudioDatabase.validate(
          'studio.planApproval.v1.x',
          jsonEncode({'approved': true}),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'unsaved complete plan cannot be approved; disposed writes do not publish',
    () async {
      final records = ControlledRecords()..failWrite = 3;
      final controller = await planned(records);
      expect(controller.hasUnsavedResponse, true);
      expect(controller.canApprovePlan, false);
      await controller.setPlanApproval(true);
      expect(records.writes, 3);
      await controller.retrySavingResponse();
      expect(controller.canApprovePlan, true);
      records.gate = Completer<void>();
      final saving = controller.setPlanApproval(true);
      controller.dispose();
      records.gate!.complete();
      await saving;
      expect(controller.planApproved, false);
      await controller.setPlanApproval(true);
      expect(records.writes, 5);
      expect(PlanApprovalStore(records).load(project.id)!.approved, true);
    },
  );

  testWidgets('explicit approval and withdrawal display persisted status', (
    tester,
  ) async {
    final records = ControlledRecords();
    final controller = (await tester.runAsync(() => planned(records)))!;
    await tester.pumpWidget(
      MaterialApp(
        home: ModelChat(project: project, controller: controller),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Approve latest saved plan'));
    await tester.pumpAndSettle();
    expect(
      find.text('Latest saved plan approved for these requirements.'),
      findsOneWidget,
    );
    expect(PlanApprovalStore(records).load(project.id)!.approved, true);
    await tester.tap(find.text('Withdraw approval'));
    await tester.pumpAndSettle();
    expect(PlanApprovalStore(records).load(project.id)!.approved, false);
    expect(find.textContaining('No current plan approval.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('approval failure and retry scroll on narrow screens', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    tester.view.devicePixelRatio = 1;
    for (final width in [280.0, 320.0, 400.0]) {
      tester.view.physicalSize = Size(width, 600);
      final records = ControlledRecords();
      final controller = (await tester.runAsync(() => planned(records)))!;
      await controller.setPlanApproval(true);
      records.failWrite = records.writes + 1;
      await controller.setPlanApproval(false);
      expect(controller.error, contains('could not be saved'));
      await tester.pumpWidget(
        MaterialApp(
          home: ModelChat(project: project, controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: 'width $width');
      final withdrawal = find.text('Withdraw approval').hitTestable();
      for (
        var scroll = 0;
        scroll < 20 && withdrawal.evaluate().isEmpty;
        scroll++
      ) {
        await tester.drag(find.byType(ListView), const Offset(0, -80));
        await tester.pumpAndSettle();
      }
      expect(withdrawal, findsOneWidget);
      await tester.tap(withdrawal);
      await tester.pumpAndSettle();
      expect(controller.hasApproval, false);
      expect(controller.error, isNull);
      expect(tester.takeException(), isNull, reason: 'retry width $width');
      await tester.pumpWidget(const SizedBox());
    }
  });
}
