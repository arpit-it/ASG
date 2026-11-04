// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/chat_message.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/html/html_operation_plan.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/html/html_starter_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/views/model_chat.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'html_planning_test.dart' as html;
import 'planning_conversation_test.dart' show PlanningProvider;

String fence(Object value) => '```asg-html-plan\n${jsonEncode(value)}\n```';
Map<String, Object?> contract() =>
    jsonDecode(HtmlOperationPlan.contract.split('\n')[1])
        as Map<String, Object?>;

void main() {
  test('strict HTML graph accepts only identity check followed by preview', () {
    final parsed = HtmlOperationPlan.parse(
      HtmlOperationPlan.contract,
      board: RequirementsBoard(),
    );
    expect(parsed.tasks.map((task) => task.operation), ['checkSources', 'run']);
    expect(parsed.preview, contains('Start local starter preview'));
    expect(() => parsed.tasks.clear(), throwsUnsupportedError);
    expect(
      () => parsed.tasks.last.dependencies.clear(),
      throwsUnsupportedError,
    );
    final mutations = <void Function(Map<String, Object?>)>[
      (v) => v['version'] = 1.0,
      (v) => v['version'] = 2,
      (v) => v['adapter'] = 'flutter-starter',
      (v) => v['command'] = 'shell',
      (v) => (v['tasks'] as List).removeLast(),
      (v) => (v['tasks'] as List)[1]['operation'] = 'open',
      (v) => (v['tasks'] as List)[0]['operation'] = 'test',
      (v) => (v['tasks'] as List)[1]['dependencies'] = [],
      (v) => (v['tasks'] as List)[1]['dependencies'] = ['check', 'check'],
      (v) => (v['tasks'] as List)[0]['dependencies'] = ['preview'],
      (v) => (v['tasks'] as List)[1]['id'] = 'check',
      (v) => (v['tasks'] as List)[0]['id'] = '../private',
      (v) => (v['tasks'] as List)[0]['command'] = 'shell',
      (v) => (v['tasks'] as List)[0]['boardTaskId'] = null,
      (v) => (v['tasks'] as List)[0]['boardTaskId'] = 'T1',
    ];
    for (final mutate in mutations) {
      final value = contract();
      mutate(value);
      expect(
        () => HtmlOperationPlan.parse(fence(value), board: RequirementsBoard()),
        throwsFormatException,
        reason: jsonEncode(value),
      );
    }
    for (final content in [
      '${HtmlOperationPlan.contract}\n${HtmlOperationPlan.contract}',
      '${HtmlOperationPlan.contract}\n```asg-build\n{}\n```',
      HtmlOperationPlan.contract.replaceFirst(
        '"version":1',
        '"version":1,"version":1',
      ),
      HtmlOperationPlan.contract.replaceFirst(
        '"id":"check"',
        '"id":"check","id":"check"',
      ),
      HtmlOperationPlan.contract.replaceFirst(
        'asg-html-plan\n',
        'asg-html-plan extra\n',
      ),
      '${'x' * 65537}${HtmlOperationPlan.contract}',
    ]) {
      expect(
        () => HtmlOperationPlan.parse(content, board: RequirementsBoard()),
        throwsFormatException,
      );
    }
  });

  test('mapped graph covers complete current board prerequisites', () {
    RequirementsBoard board({bool missing = false}) => RequirementsBoard(
      requirements: [
        ProjectRequirement(id: 'R1', title: 'Site', acceptance: 'Usable'),
      ],
      tasks: [
        DevelopmentTask(
          id: 'T1',
          requirementId: 'R1',
          title: 'Check',
          dependencies: missing ? ['T0'] : [],
        ),
        DevelopmentTask(
          id: 'T2',
          requirementId: 'R1',
          title: 'Preview',
          dependencies: ['T1'],
        ),
      ],
    );
    final value = contract();
    (value['tasks'] as List)[0]['boardTaskId'] = 'T1';
    (value['tasks'] as List)[1]['boardTaskId'] = 'T2';
    expect(
      HtmlOperationPlan.parse(fence(value), board: board()).preview,
      contains('board task: T2'),
    );
    expect(
      () => HtmlOperationPlan.parse(fence(value), board: RequirementsBoard()),
      throwsFormatException,
    );
    expect(
      () => HtmlOperationPlan.parse(fence(value), board: board(missing: true)),
      throwsFormatException,
    );
    (value['tasks'] as List)[0]['boardTaskId'] = 'T2';
    expect(
      () => HtmlOperationPlan.parse(fence(value), board: board()),
      throwsFormatException,
    );
    (value['tasks'] as List)[0]['boardTaskId'] = 'T1';
    (value['tasks'] as List)[1]['boardTaskId'] = 'T1';
    expect(
      HtmlOperationPlan.parse(fence(value), board: board()).tasks.length,
      2,
    );
  });

  for (final damage in ['board', 'starter', 'project', 'plan']) {
    test('HTML preview rereads $damage without writes or approval', () async {
      final records = await html.seed();
      await ConversationStore(records).save(html.project.id, [
        ChatMessage(
          role: 'assistant',
          content: HtmlOperationPlan.contract,
          planContext: PlanApprovalStore(records).contextFor(html.project),
        ),
      ]);
      final controller = html.chat(records, PlanningProvider());
      addTearDown(() {
        if (!controller.isDisposed) controller.dispose();
      });
      await controller.load();
      final writes = records.writes;
      expect(controller.executionPlanPreview, contains('Validated fixed HTML'));
      expect(controller.executionPlanPreview, contains('starts nothing'));
      expect(controller.canApprovePlan, false);
      expect(records.writes, writes);
      final key = switch (damage) {
        'board' => 'studio.requirements.v1.${html.project.id}',
        'starter' => HtmlStarterStore.key,
        'project' => 'studio.projects.v1',
        _ => 'studio.chat.v1.${html.project.id}',
      };
      final saved = records.values[key]!;
      records.values[key] = 'PRIVATE_SECRET /private/file';
      final preview = controller.executionPlanPreview;
      expect(preview, contains('Check saved project data'));
      expect(preview, isNot(contains('PRIVATE_SECRET')));
      expect(records.writes, writes);
      records.values[key] = saved;
      expect(controller.executionPlanPreview, contains('Validated fixed HTML'));
      final board = RequirementsStore(records);
      await board.save(
        html.project.id,
        board.load(html.project.id),
        board.load(html.project.id),
      );
      expect(controller.executionPlanPreview, contains('outdated'));
      controller.busy = true;
      expect(controller.executionPlanPreview, contains('Wait until'));
      controller.dispose();
      expect(controller.executionPlanPreview, contains('unavailable'));
    });
  }

  testWidgets('HTML operation proposal remains readable at 320px and 2x text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = await html.seed();
    await ConversationStore(records).save(html.project.id, [
      ChatMessage(
        role: 'assistant',
        content: HtmlOperationPlan.contract,
        planContext: PlanApprovalStore(records).contextFor(html.project),
      ),
    ]);
    final controller = html.chat(records, PlanningProvider());
    controller.selectMode(ConversationMode.plan);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: ModelChat(project: html.project, controller: controller),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final preview = find.textContaining(
      'Validated fixed HTML operation proposal',
    );
    await tester.scrollUntilVisible(
      preview,
      200,
      scrollable: find
          .byWidgetPredicate(
            (w) => w is Scrollable && w.axisDirection == AxisDirection.down,
          )
          .first,
    );
    expect(preview, findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'Approve latest saved plan'),
          )
          .onPressed,
      isNull,
    );
    expect(tester.takeException(), isNull);
    expect(PlanApprovalStore(records).load(html.project.id), isNull);
  });
}
