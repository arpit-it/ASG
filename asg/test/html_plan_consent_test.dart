// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:io';

import 'package:asg/controllers/chat_controller.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/html/html_operation_plan.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/html/html_starter_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/views/model_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'html_planning_test.dart' as html;
import 'planning_conversation_test.dart'
    show ControlledRecords, PlanningProvider, tick;

class ConsentRecords extends ControlledRecords
    implements ConditionalRecordStorage {
  Completer<void>? transactionGate;
  bool fail = false;
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    await transactionGate?.future;
    if (fail) throw StateError('Storage unavailable');
    for (final entry in expected.entries) {
      if (values[entry.key] != entry.value) throw StateError('Conflict');
    }
    authorize();
    values.addAll(updates);
  }
}

Future<ConsentRecords> seed() async {
  final records = ConsentRecords()..values.addAll((await html.seed()).values);
  await ConversationStore(records).save(html.project.id, [
    ChatMessage(
      role: 'assistant',
      content: HtmlOperationPlan.contract,
      planContext: PlanApprovalStore(records).contextFor(html.project),
    ),
  ]);
  return records;
}

ChatController chat(RecordStorage records) => ChatController(
  html.project,
  openStore: () async => ConversationStore(records),
  createProvider: (_) => PlanningProvider(),
);
const approvalKey = 'studio.planApproval.v1.html-plan';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'consent save retry and stale withdrawal preserve all other records',
    () async {
      final records = await seed();
      final active = chat(records);
      addTearDown(active.dispose);
      await active.load();
      expect(active.canApprovePlan, true);
      records.fail = true;
      await active.setPlanApproval(true);
      expect(active.error, isNotNull);
      expect(active.planApproved, false);
      expect(records.values[approvalKey], isNull);
      records.fail = false;
      final before = Map.of(records.values);
      await active.setPlanApproval(true);
      expect(active.planApproved, true);
      expect(
        PlanApprovalStore(records)
            .hasCurrentHtmlConsent(html.project, active.messages),
        true,
      );
      expect(
        () => PlanApprovalStore(records).requireCurrentApproval(html.project),
        throwsStateError,
      );
      expect({...records.values}..remove(approvalKey), before);
      final reopened = chat(records);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.planApproved, true);
      final board = RequirementsStore(records);
      await board.save(
        html.project.id,
        board.load(html.project.id),
        board.load(html.project.id),
      );
      expect(reopened.planApproved, false);
      expect(reopened.outdatedApproval, true);
      expect(reopened.canApprovePlan, false);
      await reopened.setPlanApproval(false);
      expect(PlanApprovalStore(records).load(html.project.id)!.approved, false);
    },
  );

  for (final key in [
    'studio.projects.v1',
    HtmlStarterStore.key,
    'studio.requirements.v1.html-plan',
    'studio.chat.v1.html-plan',
    approvalKey,
  ]) {
    test(
      'transaction refuses concurrent $key change without replacing it',
      () async {
        final records = await seed();
        final active = chat(records);
        addTearDown(active.dispose);
        await active.load();
        records.transactionGate = Completer<void>();
        final pending = active.setPlanApproval(true);
        await tick();
        expect(active.busy, true);
        expect(active.canApprovePlan, false);
        records.values[key] = 'PRIVATE /private/file';
        final before = Map.of(records.values);
        records.transactionGate!.complete();
        await pending;
        expect(records.values, before);
        expect(active.error, isNot(contains('PRIVATE')));
        expect(active.planApproved, false);
      },
    );
  }

  for (final damage in [
    'contract',
    'conversation',
    'board',
    'starter',
    'project',
    'approval',
  ]) {
    test(
      'invalid $damage refuses approval and retains saved evidence',
      () async {
        final records = await seed();
        final active = chat(records);
        addTearDown(active.dispose);
        await active.load();
        if (damage == 'contract') {
          await ConversationStore(records).save(html.project.id, [
            ChatMessage(
              role: 'assistant',
              content: '```asg-html-plan\n{}\n```',
              planContext: PlanApprovalStore(records).contextFor(html.project),
            ),
          ]);
        } else {
          final key = switch (damage) {
            'conversation' => 'studio.chat.v1.html-plan',
            'board' => 'studio.requirements.v1.html-plan',
            'starter' => HtmlStarterStore.key,
            'project' => 'studio.projects.v1',
            _ => approvalKey,
          };
          records.values[key] = 'PRIVATE /private/file';
        }
        final before = Map.of(records.values);
        await expectLater(
          PlanApprovalStore(records).save(html.project, active.messages, true),
          throwsA(anything),
        );
        expect(records.values, before);
        expect(active.planApproved, false);
      },
    );
  }

  test('closing screen revokes pending consent publication', () async {
    final records = await seed();
    final active = chat(records);
    await active.load();
    records.transactionGate = Completer<void>();
    final pending = active.setPlanApproval(true);
    await tick();
    active.dispose();
    records.transactionGate!.complete();
    await pending;
    expect(records.values[approvalKey], isNull);
    expect(active.canApprovePlan, false);
  });

  test(
    'native database retains exact consent through reopen and withdrawal',
    () async {
      final initial = await seed();
      final dir = await Directory.systemTemp.createTemp('asg-html-consent-');
      addTearDown(() => dir.delete(recursive: true));
      final path = '${dir.path}/data.db';
      final prefs = await SharedPreferences.getInstance();
      var native = await databaseFactoryIo.openDatabase(path);
      var records = await StudioDatabase.migrate(native, prefs);
      for (final entry in initial.values.entries) {
        if (entry.key.contains('studio.application.')) continue;
        await records.setString(entry.key, entry.value);
      }
      final messages = ConversationStore(records).load(html.project.id);
      await PlanApprovalStore(records).save(html.project, messages, true);
      final saved = records.getString(approvalKey);
      await native.close();
      native = await databaseFactoryIo.openDatabase(path);
      addTearDown(native.close);
      records = await StudioDatabase.migrate(native, prefs);
      expect(records.getString(approvalKey), saved);
      expect(
        PlanApprovalStore(records)
            .hasCurrentHtmlConsent(html.project, messages),
        true,
      );
      expect(
        () => PlanApprovalStore(records).requireCurrentApproval(html.project),
        throwsStateError,
      );
      await PlanApprovalStore(records).save(html.project, messages, false);
      expect(PlanApprovalStore(records).load(html.project.id)!.approved, false);
    },
  );

  testWidgets('320px 2x consent approval and withdrawal stay reachable', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = await seed();
    final active = chat(records)..selectMode(ConversationMode.plan);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: ModelChat(project: html.project, controller: active),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final scroll = find
        .byWidgetPredicate(
          (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
        )
        .first;
    final approve = find.text('Approve latest saved plan');
    await tester.scrollUntilVisible(approve, 180, scrollable: scroll);
    await tester.tap(approve);
    await tester.pumpAndSettle();
    expect(active.planApproved, true);
    final withdraw = find.text('Withdraw approval');
    await tester.scrollUntilVisible(withdraw, 180, scrollable: scroll);
    await tester.tap(withdraw);
    await tester.pumpAndSettle();
    expect(active.hasApproval, false);
    expect(tester.takeException(), isNull);
  });
}
