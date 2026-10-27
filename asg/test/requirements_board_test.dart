// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/project.dart';

import 'dart:async';
import 'dart:io';

import 'package:asg/controllers/requirements_controller.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/views/requirements_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'project_details_test.dart' show Records;
import 'plan_approval_test.dart' show planned;
import 'planning_conversation_test.dart'
    show ControlledRecords, project, chat, PlanningProvider, tick;

import 'package:asg/models/generation_event.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';

const requirement = ProjectRequirement(
  id: 'R1',
  title: 'Task list',
  acceptance: 'A saved task is visible after restart.',
);
DevelopmentTask task(
  String id, {
  List<String> deps = const [],
  TaskStatus status = TaskStatus.queued,
}) => DevelopmentTask(
  id: id,
  requirementId: 'R1',
  title: 'Implement $id',
  dependencies: deps,
  status: status,
);
RequirementsController board(Records records) =>
    RequirementsController('project', RequirementsStore(records))..load();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('validates IDs, criteria, task references and dependency graphs', () {
    final invalid = [
      RequirementsBoard(requirements: [requirement, requirement]),
      RequirementsBoard(
        requirements: [
          const ProjectRequirement(
            id: '../R',
            title: 'Bad',
            acceptance: 'Accept',
          ),
        ],
      ),
      RequirementsBoard(
        requirements: [
          const ProjectRequirement(id: 'R', title: 'Bad', acceptance: ' '),
        ],
      ),
      RequirementsBoard(tasks: [task('T1')]),
      RequirementsBoard(
        requirements: [requirement],
        tasks: [task('T1'), task('T1')],
      ),
      RequirementsBoard(
        requirements: [requirement],
        tasks: [
          task('T1', deps: ['missing']),
        ],
      ),
      RequirementsBoard(
        requirements: [requirement],
        tasks: [
          task('T1', deps: ['T1']),
        ],
      ),
      RequirementsBoard(
        requirements: [requirement],
        tasks: [
          task('T1', deps: ['T2']),
          task('T2', deps: ['T1']),
        ],
      ),
      RequirementsBoard(
        requirements: [requirement],
        tasks: [
          task('T1'),
          task('T2', deps: ['T1', 'T1']),
        ],
      ),
      RequirementsBoard(
        requirements: [requirement],
        tasks: [
          task('T1'),
          task('T2', deps: ['T1'], status: TaskStatus.done),
        ],
      ),
    ];
    for (final value in invalid) {
      expect(value.validate, throwsFormatException);
    }
  });

  test('status edits, transitive reopen, requirement edits and document survive reopen', () async {
    final records = Records();
    final c = board(records);
    addTearDown(c.dispose);
    expect(await c.saveRequirement(requirement), true);
    expect(await c.saveRequirement(requirement), false);
    expect(await c.saveTask(task('T1', status: TaskStatus.done)), true);
    expect(
      await c.saveTask(task('T2', deps: ['T1'], status: TaskStatus.done)),
      true,
    );
    expect(
      await c.saveTask(task('T3', deps: ['T2'], status: TaskStatus.done)),
      true,
    );
    expect(await c.saveTask(task('T1'), editing: true), true);
    expect(c.board!.tasks.every((t) => t.status == TaskStatus.queued), true);
    expect(
      await c.saveTask(
        task('T2', deps: ['T1'], status: TaskStatus.done),
        editing: true,
      ),
      false,
    );
    expect(
      await c.saveTask(task('T1', status: TaskStatus.done), editing: true),
      true,
    );
    expect(
      await c.saveRequirement(
        const ProjectRequirement(
          id: 'R1',
          title: 'Changed',
          acceptance: 'New criteria',
        ),
        editing: true,
      ),
      true,
    );
    expect(c.board!.tasks.every((t) => t.status == TaskStatus.queued), true);
    final reopened = board(records);
    addTearDown(reopened.dispose);
    expect(reopened.board!.revision, c.board!.revision);
    expect(reopened.board!.requirements.single.title, 'Changed');
    expect(
      reopened.board!.document('App'),
      contains('T3: Implement T3 (queued); dependencies: T2'),
    );
  });

  test('failed writes, stale and concurrent editors, corruption and disposal preserve evidence', () async {
    final records = Records();
    final c = board(records);
    addTearDown(c.dispose);
    records.failKey = RequirementsStore.key('project');
    expect(await c.saveRequirement(requirement), false);
    expect(c.board!.revision, 0);
    expect(records.values, isEmpty);
    records.failKey = null;
    final stale = board(records);
    addTearDown(stale.dispose);
    records.delayKey = RequirementsStore.key('project');
    records.gate = Completer<void>();
    final saving = c.saveRequirement(requirement);
    expect(await c.saveRequirement(requirement), false);
    expect(await stale.saveRequirement(requirement), false);
    records.gate!.complete();
    expect(await saving, true);
    expect(await stale.saveRequirement(requirement), false);
    expect(stale.error, contains('Reopen'));
    records.delayKey = null;
    final disposed = board(records);
    disposed.dispose();
    expect(await disposed.saveRequirement(requirement), false);
    final raw = records.values[RequirementsStore.key('project')];
    records.values[RequirementsStore.key('project')] = 'corrupt';
    final damaged = board(records);
    addTearDown(damaged.dispose);
    expect(damaged.board, isNull);
    expect(damaged.error, contains('unreadable'));
    expect(await damaged.saveRequirement(requirement), false);
    expect(records.values[RequirementsStore.key('project')], 'corrupt');
    expect(raw, isNotNull);
  });

  test('native transactional storage reopens requirements and isolates damaged records', () async {
    final dir = await Directory.systemTemp.createTemp('asg-requirements-');
    addTearDown(() => dir.delete(recursive: true));
    final prefs = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${dir.path}/studio.db');
    var storage = await StudioDatabase.migrate(db, prefs);
    final store = RequirementsStore(storage);
    await store.save(
      'project',
      store.load('project'),
      RequirementsBoard(requirements: [requirement], tasks: [task('T1')]),
    );
    await db.close();
    db = await databaseFactoryIo.openDatabase('${dir.path}/studio.db');
    storage = await StudioDatabase.migrate(db, prefs);
    expect(RequirementsStore(storage).load('project').tasks.single.id, 'T1');
    await StoreRef<String, String>('records')
        .record(RequirementsStore.key('project'))
        .put(db, 'broken');
    await db.close();
    db = await databaseFactoryIo.openDatabase('${dir.path}/studio.db');
    addTearDown(db.close);
    storage = await StudioDatabase.migrate(db, prefs);
    expect(
      () => RequirementsStore(storage).load('project'),
      throwsFormatException,
    );
    expect(RequirementsStore(storage).load('other').revision, 0);
  });

  test('structured changes invalidate approvals immediately and after revert/reopen', () async {
    final records = ControlledRecords();
    final c = await planned(records);
    addTearDown(c.dispose);
    await c.setPlanApproval(true);
    expect(c.planApproved, true);
    final store = RequirementsStore(records);
    final first = await store.save(
      project.id,
      store.load(project.id),
      RequirementsBoard(requirements: [requirement]),
    );
    expect(c.planApproved, false);
    expect(c.canApprovePlan, false);
    await store.save(project.id, first, RequirementsBoard());
    expect(c.planApproved, false);
    final reopened = chat(records, PlanningProvider());
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.outdatedApproval, true);
    expect(reopened.canApprovePlan, false);
    expect(PlanApprovalStore(records).load(project.id)!.approved, true);
  });

  test(
    'plan captures requirements at request start and includes readable context',
    () async {
      final records = ControlledRecords();
      final provider = PlanningProvider();
      final c = chat(records, provider);
      addTearDown(c.dispose);
      await c.load();
      final store = RequirementsStore(records);
      final first = await store.save(
        project.id,
        store.load(project.id),
        RequirementsBoard(requirements: [requirement]),
      );
      c.selectMode(ConversationMode.plan);
      final sending = c.send('Plan');
      await tick();
      expect(
        provider.prompt,
        contains('A saved task is visible after restart.'),
      );
      await store.save(project.id, first, RequirementsBoard());
      provider.events.add(const GenerationEvent.text('A plan'));
      await provider.events.close();
      await sending;
      expect(c.canApprovePlan, false);
      expect(
        ConversationStore(records).load(project.id).last.planContext,
        contains('"requirementsRevision":1'),
      );
    },
  );

  test('fresh structured plan approves exact board; corrupted requirements fail closed', () async {
    final records = ControlledRecords();
    final store = RequirementsStore(records);
    await store.save(
      project.id,
      store.load(project.id),
      RequirementsBoard(requirements: [requirement]),
    );
    final c = await planned(records);
    addTearDown(c.dispose);
    expect(c.canApprovePlan, true);
    await c.setPlanApproval(true);
    expect(c.planApproved, true);
    records.values[RequirementsStore.key(project.id)] = 'corrupt';
    expect(c.planApproved, false);
    expect(c.canApprovePlan, false);
    expect(await c.send('Do not infer using corrupted requirements'), false);
    expect(records.values[RequirementsStore.key(project.id)], 'corrupt');
  });

  testWidgets('task status edit and reopen work from the narrow board', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(320, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final records = Records();
    final c = board(records);
    await c.saveRequirement(requirement);
    await c.saveTask(task('T1', status: TaskStatus.done));
    await tester.pumpWidget(
      MaterialApp(
        home: RequirementsScreen(controller: c, projectName: 'App'),
      ),
    );
    await tester.pumpAndSettle();
    for (
      var scroll = 0;
      scroll < 10 && find.text('Reopen T1').hitTestable().evaluate().isEmpty;
      scroll++
    ) {
      await tester.drag(find.byType(ListView), const Offset(0, -150));
      await tester.pumpAndSettle();
    }
    expect(find.text('Reopen T1').hitTestable(), findsOneWidget);
    await tester.tap(find.text('Reopen T1'));
    await tester.pumpAndSettle();
    expect(c.board!.tasks.single.status, TaskStatus.queued);
    await tester.ensureVisible(find.text('Edit T1'));
    await tester.tap(find.text('Edit T1'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Implement T1'),
      'Implement saved tasks',
    );
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(c.board!.tasks.single.title, 'Implement saved tasks');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'narrow editor retains failed draft and board document restores saved edits',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final records = Records();
      final c = board(records);
      await tester.pumpWidget(
        MaterialApp(
          home: RequirementsScreen(controller: c, projectName: 'App'),
        ),
      );
      await tester.tap(find.text('Add requirement'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Stable ID'), 'R1');
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Task list',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Acceptance criteria'),
        'Saved after restart',
      );
      records.failKey = RequirementsStore.key('project');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.widgetWithText(TextField, 'Task list'), findsOneWidget);
      expect(c.board!.requirements, isEmpty);
      records.failKey = null;
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('R1: Task list'), findsOneWidget);
      await tester.tap(find.text('Read document'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Acceptance criteria:\nSaved after restart'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(
        MaterialApp(
          home: RequirementsScreen(
            controller: board(records),
            projectName: 'App',
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('R1: Task list'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
