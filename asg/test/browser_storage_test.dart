// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('browser')
library;

import 'package:asg/models/chat_message.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/models/build_task.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/requirements_store.dart';

import 'package:asg/services/studio_database.dart';
import 'package:asg/models/plan_approval.dart';

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast_web/sembast_web.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'IndexedDB migration, failed transaction and reopen retain data',
    () async {
      final name = 'asg-test-${DateTime.now().microsecondsSinceEpoch}';
      SharedPreferences.setMockInitialValues({
        'studio.lastProject.v1': 'legacy',
      });
      final prefs = await SharedPreferences.getInstance();
      var db = await databaseFactoryWeb.openDatabase(
        name,
        mode: DatabaseMode.create,
      );
      try {
        await expectLater(
          StudioDatabase.migrate(
            db,
            prefs,
            beforeCommit: () async => throw StateError('interrupted'),
          ),
          throwsStateError,
        );
        final records = await StudioDatabase.migrate(db, prefs);
        expect(records.getString('studio.lastProject.v1'), 'legacy');
        await records.setString('studio.lastProject.v1', 'updated');
        final approval = jsonEncode(
          PlanApproval(
            messageIndex: 1,
            content: 'Exact plan',
            context: 'Exact requirements',
            approved: true,
            recordedAt: DateTime.utc(2026, 10, 25),
          ).toJson(),
        );
        await records.setString('studio.planApproval.v1.p', approval);
        await SourceGenerationStore(records).save(
          'p',
          GeneratedProject(
            tasks: BuildTask.starter,
            directory: '/generated',
            sdk: '/sdk',
            python: 'python3',
            sources: {'lib/main.dart': '0' * 64},
            approval: PlanApproval.fromJson(
              jsonDecode(approval) as Map<String, dynamic>,
            ),
          ),
        );
        final requirements = RequirementsStore(records);
        await requirements.save(
          'p',
          requirements.load('p'),
          RequirementsBoard(
            requirements: [
              ProjectRequirement(
                id: 'R1',
                title: 'Saved requirement',
                acceptance: 'Reopen in Chrome',
              ),
            ],
            tasks: [
              DevelopmentTask(
                id: 'T1',
                requirementId: 'R1',
                title: 'Verify persistence',
              ),
            ],
          ),
        );
        await db.close();
        db = await databaseFactoryWeb.openDatabase(
          name,
          mode: DatabaseMode.create,
        );
        final restored = await StudioDatabase.migrate(db, prefs);
        expect(restored.getString('studio.lastProject.v1'), 'updated');
        expect(restored.getString('studio.planApproval.v1.p'), approval);
        expect(
          jsonEncode(
            SourceGenerationStore(restored).load('p')!.approval!.toJson(),
          ),
          approval,
        );
        expect(RequirementsStore(restored).load('p').tasks.single.id, 'T1');
        expect(prefs.getString('studio.lastProject.v1'), 'legacy');
        final raw = StoreRef<String, String>('records');
        const appKey = 'studio.application.v1.damaged';
        const generationKey = 'studio.generation.v1.damaged';
        await raw.record(appKey).put(db, 'broken app');
        await raw.record(generationKey).put(db, 'broken generation');
        expect(
          SourceGenerationStore(restored).load('p')!.tasks!.map((t) => t.id),
          BuildTask.starter.map((t) => t.id),
        );
        const approvalKey = 'studio.planApproval.v1.damaged';
        await raw.record(approvalKey).put(db, 'broken approval');
        final requirementsKey = RequirementsStore.key('damaged');
        await raw.record(requirementsKey).put(db, 'broken requirements');
        await db.close();
        db = await databaseFactoryWeb.openDatabase(
          name,
          mode: DatabaseMode.create,
        );
        final isolated = await StudioDatabase.migrate(db, prefs);
        expect(isolated.getString('studio.lastProject.v1'), 'updated');
        expect(() => isolated.getString(appKey), throwsFormatException);
        expect(
          () => RequirementsStore(isolated).load('damaged'),
          throwsFormatException,
        );
        expect(
          await raw.record(requirementsKey).get(db),
          'broken requirements',
        );
        expect(RequirementsStore(isolated).load('p').revision, 1);
        expect(() => isolated.getString(approvalKey), throwsFormatException);
        expect(await raw.record(approvalKey).get(db), 'broken approval');
        expect(isolated.getString('studio.planApproval.v1.p'), approval);
        expect(() => isolated.getString(generationKey), throwsFormatException);
        expect(await raw.record(appKey).get(db), 'broken app');
        expect(await raw.record(generationKey).get(db), 'broken generation');
        await expectLater(
          isolated.setString(appKey, 'invalid'),
          throwsFormatException,
        );
      } finally {
        await db.close();
        await databaseFactoryWeb.deleteDatabase(name);
      }
    },
  );
  for (final change in ['requirements', 'prototype', 'draft']) {
    test('IndexedDB approval refuses stale $change after reopen', () async {
      final name = 'asg-plan-$change-${DateTime.now().microsecondsSinceEpoch}';
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var db = await databaseFactoryWeb.openDatabase(name);
      const project = StudioProject(
        id: 'browser-plan',
        name: 'Browser plan',
        description: 'Track tasks',
        type: 'Flutter',
        platforms: ['Web'],
        location: '',
      );
      try {
        var records = await StudioDatabase.migrate(db, prefs);
        await StudioStore(records).save([project]);
        var approvals = PlanApprovalStore(records);
        var messages = [
          ChatMessage(
            role: 'assistant',
            content: 'Exact saved plan',
            planContext: approvals.contextFor(project),
          ),
        ];
        await ConversationStore(records).save(project.id, messages);
        await approvals.save(project, messages, true);
        final original = approvals.requireCurrentApproval(project).toJson();
        await db.close();
        db = await databaseFactoryWeb.openDatabase(name);
        records = await StudioDatabase.migrate(db, prefs);
        approvals = PlanApprovalStore(records);
        expect(approvals.requireCurrentApproval(project).toJson(), original);
        if (change == 'requirements') {
          final store = RequirementsStore(records);
          await store.save(
            project.id,
            store.load(project.id),
            RequirementsBoard(
              requirements: [
                ProjectRequirement(
                  id: 'R1',
                  title: 'Changed task',
                  acceptance: 'The changed task is retained',
                ),
              ],
            ),
          );
        } else if (change == 'prototype') {
          final apps = ApplicationStore(records);
          final saved = apps.load(project);
          await apps.save(
            project.id,
            ApplicationSnapshot(
              saved.definition,
              saved.messages,
              saved.revision + 1,
            ),
          );
        } else {
          await ConversationStore(records).save(project.id, [
            ...messages,
            ChatMessage(
              role: 'assistant',
              content: 'New draft',
              planContext: approvals.contextFor(project),
            ),
          ]);
        }
        await db.close();
        db = await databaseFactoryWeb.openDatabase(name);
        records = await StudioDatabase.migrate(db, prefs);
        approvals = PlanApprovalStore(records);
        expect(
          () => approvals.requireCurrentApproval(project),
          throwsStateError,
        );
        await expectLater(
          approvals.save(project, messages, true),
          throwsStateError,
        );
        expect(approvals.load(project.id)!.toJson(), original);
        messages = [
          ChatMessage(
            role: 'assistant',
            content: 'Fresh reviewed plan',
            planContext: approvals.contextFor(project),
          ),
        ];
        await ConversationStore(records).save(project.id, messages);
        await approvals.save(project, messages, true);
        expect(
          approvals.requireCurrentApproval(project).content,
          'Fresh reviewed plan',
        );
        await approvals.save(project, messages, false);
        await db.close();
        db = await databaseFactoryWeb.openDatabase(name);
        records = await StudioDatabase.migrate(db, prefs);
        approvals = PlanApprovalStore(records);
        expect(approvals.load(project.id)!.approved, isFalse);
        expect(
          () => approvals.requireCurrentApproval(project),
          throwsStateError,
        );
        expect(
          ConversationStore(records).load(project.id).single.content,
          'Fresh reviewed plan',
        );
        const key = 'studio.planApproval.v1.browser-plan';
        final raw = StoreRef<String, String>('records');
        await raw.record(key).put(db, 'broken approval');
        await db.close();
        db = await databaseFactoryWeb.openDatabase(name);
        records = await StudioDatabase.migrate(db, prefs);
        approvals = PlanApprovalStore(records);
        expect(
          () => approvals.requireCurrentApproval(project),
          throwsFormatException,
        );
        await expectLater(
          approvals.save(project, messages, true),
          throwsFormatException,
        );
        expect(await raw.record(key).get(db), 'broken approval');
        expect(
          ConversationStore(records).load(project.id).single.content,
          'Fresh reviewed plan',
        );
      } finally {
        await db.close();
        await databaseFactoryWeb.deleteDatabase(name);
      }
    });
  }
}
