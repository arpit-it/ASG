import 'dart:io';

import 'package:asg/models/app_definition.dart';

import 'package:asg/models/plan_approval.dart';

import 'dart:convert';

import 'package:asg/services/portable_decision_store.dart';
import 'package:asg/services/portable_revision_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/controllers/portable_archive_controller.dart';

import 'package:asg/services/portable_workspace_restore.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/application_store.dart';

import 'package:asg/models/chat_message.dart';
import 'package:asg/models/portable_project_archive.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/portable_archive_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

String withoutProjectIntent(PortableProjectArchive value) =>
    PortableProjectArchive(
      requirements: value.requirements,
      messages: value.messages,
      prototype: value.prototype,
      decision: value.decision,
      revisions: value.revisions,
    ).encode();

void main() {
  test(
    'invalid or ambiguous local input revision metadata refuses summary',
    () {
      for (final context in [
        '{"requirementsRevision":1}',
        '{"requirementsRevision":1,"prototypeRevision":0}',
        '{"requirementsRevision":1,"requirementsRevision":2,"prototypeRevision":3}',
        '{"requirementsRevision":1.5,"prototypeRevision":3}',
      ]) {
        final project = GeneratedProject(
          directory: '/private',
          sdk: '/sdk',
          python: 'python3',
          sources: {},
          phase: SourceGenerationPhase.failed,
          approval: PlanApproval(
            messageIndex: 0,
            content: 'Plan',
            context: context,
            approved: true,
            recordedAt: DateTime.utc(2026),
          ),
        );
        expect(
          () => PortableRevisionStore.summarize(project, null),
          throwsFormatException,
        );
      }
      final legacy = GeneratedProject(
        directory: '/private',
        sdk: '/sdk',
        python: 'python3',
        sources: {},
        phase: SourceGenerationPhase.failed,
        approval: PlanApproval(
          messageIndex: 0,
          content: 'Plan',
          context: 'legacy context',
          approved: true,
          recordedAt: DateTime.utc(2026),
        ),
      );
      expect(
        PortableRevisionStore.summarize(legacy, null).requirementsRevision,
        isNull,
      );
    },
  );

  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late StudioDatabase db;
  final encoded = PortableProjectArchive(
    requirements: RequirementsBoard(revision: 7),
    messages: const [ChatMessage(role: 'user', content: 'Keep exact 😀')],
  ).encode();
  Future<StudioDatabase> open() async => StudioDatabase.migrate(
    await databaseFactoryIo.openDatabase('${temp.path}/test.db'),
    await SharedPreferences.getInstance(),
  );
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('asg-archive-');
    db = await open();
  });
  tearDown(() async {
    await db.database.close();
    await temp.delete(recursive: true);
  });
  test(
    'workspace restore preserves unrelated catalog metadata after reopen',
    () async {
      final existing = {
        'id': 'existing',
        'name': ' Existing ',
        'description': 'Résumé 中文 😀',
        'type': 'Flutter',
        'platforms': ['Web'],
        'location': '/original/location',
        'futureMetadata': {
          'nested': ['Exact 中文 😀', 7, null],
        },
      };
      final catalog = jsonEncode([existing]).replaceFirst(
        '"futureMetadata":',
        '"largeNumber":9223372036854775809,"futureMetadata":',
      );
      await db.setString('studio.projects.v1', catalog);
      await PortableWorkspaceRestore(db)
          .restore(id: 'new', name: 'New', encoded: encoded);
      await db.database.close();
      db = await open();
      final rows = jsonDecode(db.getString('studio.projects.v1')!) as List;
      expect(
        db.getString('studio.projects.v1'),
        contains('"largeNumber":9223372036854775809'),
      );
      expect(rows.first, (jsonDecode(catalog) as List).first);
      expect(rows.last['id'], 'new');
      expect(StudioStore(db).load(), hasLength(2));
    },
  );
  test('project intent survives native database close and reopen', () async {
    final original = PortableProjectArchive(
      project: PortableProjectIntent(
        description: 'Exact 中文 😀',
        type: 'Rust',
        platforms: ['Linux', 'macOS'],
      ),
      requirements: RequirementsBoard(),
      messages: [],
    );
    await PortableArchiveStore(db).restoreCopy('intent', original.encode());
    await db.database.close();
    db = await open();
    await PortableWorkspaceRestore(db).restore(
      id: 'restoredIntent',
      name: 'Restored',
      encoded: PortableArchiveStore(db).load('intent')!.encode(),
    );
    await db.database.close();
    db = await open();
    final project = StudioStore(db).load().single;
    expect(project.description, 'Exact 中文 😀');
    expect(project.type, 'Rust');
    expect(project.platforms, ['Linux', 'macOS']);
    expect(project.location, '');
    final controller = PortableArchiveController(project.id, db);
    addTearDown(controller.dispose);
    await controller.prepareExport();
    expect(controller.exportContents, original.encode());
  });
  test('saved prototype survives native copy and new workspace reopen with conversation text but without consent', () async {
    const definition = AppDefinition(
      title: 'Saved 中文',
      theme: 'pink',
      elements: [
        AppElement(
          id: 'notes',
          kind: ElementKind.notes,
          label: 'Private notes',
        ),
      ],
    );
    await ApplicationStore(db).save(
      'source',
      const ApplicationSnapshot(definition, [
        ChatMessage(
          role: 'assistant',
          content: 'Saved edit chat 😀',
          planContext: '/private/context',
        ),
      ], 12),
    );
    final c = PortableArchiveController('source', db);
    addTearDown(c.dispose);
    await c.prepareExport();
    expect(c.error, isNull);
    final encoded = c.exportPreview!.encode();
    expect(encoded, contains('Saved edit chat 😀'));
    expect(encoded, isNot(contains('/private/context')));
    await PortableArchiveStore(db).restoreCopy('copy', encoded);
    await db.database.close();
    db = await open();
    final reopened = PortableArchiveController('unused', db);
    addTearDown(reopened.dispose);
    await reopened.prepareCopyExport('copy');
    expect(reopened.exportContents, encoded);
    expect(StudioStore(db).load(), isEmpty);
    await reopened.loadCopy('copy');
    expect(reopened.importContents, encoded);
    expect(StudioStore(db).load(), isEmpty);
    await reopened.restoreWorkspace('restored', 'Restored');
    expect(reopened.error, isNull);
    await db.database.close();
    db = await open();
    final project = StudioStore(db).load().single;
    final snapshot = ApplicationStore(db).load(project);
    expect(snapshot.definition.toJson(), definition.toJson());
    expect(snapshot.revision, 12);
    expect(snapshot.messages.single.toJson(), {
      'role': 'assistant',
      'content': 'Saved edit chat 😀',
    });
    expect(PortableArchiveStore(db).load('copy')!.encode(), encoded);
    final restored = PortableArchiveController('restored', db);
    addTearDown(restored.dispose);
    await restored.prepareExport();
    expect(withoutProjectIntent(restored.exportPreview!), encoded);
    expect(PlanApprovalStore(db).load('restored'), isNull);
    expect(SourceGenerationStore(db).load('restored'), isNull);
    await expectLater(
      PortableWorkspaceRestore(db)
          .restore(id: 'restored', name: 'Replace', encoded: encoded),
      throwsStateError,
    );
    expect(
      ApplicationStore(db).load(project).definition.toJson(),
      definition.toJson(),
    );
  });
  test('revision summaries survive native reopen without paths or executable history', () async {
    final generation = GeneratedProject(
      approval: PlanApproval(
        messageIndex: 0,
        content: 'Private Plan',
        context: jsonEncode({
          'requirementsRevision': 7,
          'prototypeRevision': 12,
          'project': '/private/ignored',
        }),
        approved: true,
        recordedAt: DateTime.utc(2026),
      ),
      directory: '/private/source',
      sdk: '/private/sdk',
      python: 'python3',
      sources: {'lib/main.dart': 'a' * 64},
      phase: SourceGenerationPhase.failed,
      steps: const [
        GenerationStep(
          operation: 'resolve',
          exitCode: 1,
          output: 'private log',
        ),
      ],
    );
    await SourceGenerationStore(db).save('source', generation);
    final controller = PortableArchiveController('source', db);
    addTearDown(controller.dispose);
    await controller.prepareExport();
    expect(controller.error, isNull);
    final original = controller.exportPreview!;
    expect(original.revisions.single.outcome, 'failed');
    expect(original.revisions.single.requirementsRevision, 7);
    expect(original.revisions.single.prototypeRevision, 12);
    expect(original.encode(), isNot(contains('Private Plan')));
    expect(original.encode(), isNot(contains('/private')));
    expect(original.encode(), isNot(contains('private log')));
    await PortableArchiveStore(db).restoreCopy('copy', original.encode());
    await PortableWorkspaceRestore(db)
        .restore(id: 'restored', name: 'Restored', encoded: original.encode());
    await db.database.close();
    db = await open();
    expect(PortableArchiveStore(db).load('copy')!.encode(), original.encode());
    final restored = PortableArchiveController('restored', db);
    addTearDown(restored.dispose);
    await restored.prepareExport();
    expect(withoutProjectIntent(restored.exportPreview!), original.encode());
    expect(SourceGenerationStore(db).load('restored'), isNull);
    expect(PlanApprovalStore(db).load('restored'), isNull);
    await SourceGenerationStore(db).save('restored', generation);
    await restored.prepareExport();
    expect(restored.exportPreview!.revisions.length, 2);
    expect(
      restored.exportPreview!.revisions.first.toJson(),
      original.revisions.single.toJson(),
    );
  });
  test('legacy terminal records keep unknown time and damaged local evidence blocks export', () async {
    final generation = GeneratedProject(
      directory: '/legacy',
      sdk: '/sdk',
      python: 'python3',
      sources: {'lib/main.dart': 'a' * 64},
      phase: SourceGenerationPhase.failed,
    );
    await db.setString(
      'studio.generation.v1.legacy',
      jsonEncode(generation.toJson()),
    );
    final c = PortableArchiveController('legacy', db);
    addTearDown(c.dispose);
    await c.prepareExport();
    expect(c.error, isNull);
    expect(c.exportPreview!.revisions.single.recordedAt, isNull);
    expect(c.exportPreview!.revisions.single.totalChecks, 0);
    const raw = '{"phase":"failed"}';
    await StoreRef<String, String>('records')
        .record('studio.generation.v1.broken')
        .put(db.database, raw);
    await db.database.close();
    db = await open();
    final broken = PortableArchiveController('broken', db);
    addTearDown(broken.dispose);
    await broken.prepareExport();
    expect(broken.error, isNotNull);
    expect(broken.exportPreview, isNull);
    expect(
      await StoreRef<String, String>('records')
          .record('studio.generation.v1.broken')
          .get(db.database),
      raw,
    );
  });
  test(
    'damaged revision summaries stay isolated and refuse orphan replacement',
    () async {
      final key = PortableRevisionStore.key('orphan');
      const raw = '[{"outcome":"failed","outcome":"ready"}]';
      await StoreRef<String, String>('records')
          .record(key)
          .put(db.database, raw);
      await db.database.close();
      db = await open();
      expect(
        () => PortableRevisionStore(db).load('orphan'),
        throwsFormatException,
      );
      await expectLater(
        PortableWorkspaceRestore(db)
            .restore(id: 'orphan', name: 'No', encoded: encoded),
        throwsFormatException,
      );
      expect(db.getString('studio.projects.v1'), isNull);
      expect(
        await StoreRef<String, String>('records').record(key).get(db.database),
        raw,
      );
      expect(PortableRevisionStore(db).load('other'), isEmpty);
    },
  );
  test('historical decision persists through native restore and re-export without consent', () async {
    final original = PortableProjectArchive(
      requirements: RequirementsBoard(revision: 7),
      messages: [],
      decision: PortablePlanDecision(
        content: 'Old decision 中文',
        approved: true,
        recordedAt: DateTime.utc(2026, 10, 26),
      ),
    );
    await PortableArchiveStore(db).restoreCopy('copy', original.encode());
    await PortableWorkspaceRestore(db)
        .restore(id: 'history', name: 'History', encoded: original.encode());
    await db.database.close();
    db = await open();
    expect(PortableArchiveStore(db).load('copy')!.encode(), original.encode());
    final project = StudioStore(db).load().single;
    expect(
      PortableDecisionStore(db).load(project.id)!.toJson(),
      original.decision!.toJson(),
    );
    expect(PlanApprovalStore(db).load(project.id), isNull);
    expect(
      () => PlanApprovalStore(db).requireCurrentApproval(project),
      throwsStateError,
    );
    final controller = PortableArchiveController(project.id, db);
    addTearDown(controller.dispose);
    await controller.prepareExport();
    expect(withoutProjectIntent(controller.exportPreview!), original.encode());
    // A later local decision is exported instead of the imported historical one.
    await db.setString(
      'studio.planApproval.v1.history',
      jsonEncode({
        'messageIndex': 0,
        'content': 'New local decision',
        'context': '/private/context',
        'approved': false,
        'recordedAt': '2026-10-26T01:00:00.000Z',
      }),
    );
    await controller.prepareExport();
    expect(controller.exportPreview!.decision!.content, 'New local decision');
    expect(controller.exportPreview!.decision!.approved, isFalse);
    expect(
      controller.exportPreview!.encode(),
      isNot(contains('/private/context')),
    );
  });
  test('historical orphan identity and corrupt decision cannot be replaced', () async {
    final key = PortableDecisionStore.key('orphan');
    await db.setString(
      key,
      jsonEncode(
        PortablePlanDecision(
          content: 'Retained',
          approved: false,
          recordedAt: DateTime.utc(2026),
        ).toJson(),
      ),
    );
    await expectLater(
      PortableWorkspaceRestore(db)
          .restore(id: 'orphan', name: 'Refused', encoded: encoded),
      throwsStateError,
    );
    expect(db.getString('studio.projects.v1'), isNull);
    // Inject damaged storage through the database to exercise reopen isolation.
    final raw =
        '{"content":"Lost","content":"Retained","approved":false,"recordedAt":"2026-01-01T00:00:00.000Z"}';
    await StoreRef<String, String>('records').record(key).put(db.database, raw);
    await db.database.close();
    db = await open();
    expect(
      () => PortableDecisionStore(db).load('orphan'),
      throwsFormatException,
    );
    await expectLater(
      PortableWorkspaceRestore(db)
          .restore(id: 'orphan', name: 'Refused', encoded: encoded),
      throwsFormatException,
    );
    expect(
      await StoreRef<String, String>('records').record(key).get(db.database),
      raw,
    );
    expect(db.getString('studio.projects.v1'), isNull);
    expect(PortableDecisionStore(db).load('other'), isNull);
  });
  test(
    'workspace reopen preserves records without consent or execution',
    () async {
      final archive = PortableProjectArchive(
        requirements: RequirementsBoard(
          revision: 7,
          requirements: const [
            ProjectRequirement(
              id: 'R1',
              title: 'Preserve',
              acceptance: 'Exact text',
            ),
          ],
          tasks: [
            DevelopmentTask(
              id: 'T1',
              requirementId: 'R1',
              title: 'Task',
              status: TaskStatus.done,
            ),
          ],
        ),
        messages: const [
          ChatMessage(
            role: 'assistant',
            content: 'Old plan',
            planContext: 'not-consent',
          ),
        ],
      );
      await PortableWorkspaceRestore(db)
          .restore(id: 'restored', name: 'Restored', encoded: archive.encode());
      await db.database.close();
      db = await open();
      final project = StudioStore(db).load().single;
      expect(project.id, 'restored');
      expect(project.location, isEmpty);
      expect(
        RequirementsStore(db).load(project.id).toJson(),
        archive.requirements.toJson(),
      );
      final messages = ConversationStore(db).load(project.id);
      expect(messages.single.content, 'Old plan');
      expect(messages.single.planContext, isNull);
      expect(ApplicationStore(db).load(project).revision, 1);
      for (final namespace in [
        'planApproval',
        'application',
        'generation',
        'sourceCandidate',
      ]) {
        expect(db.getString('studio.$namespace.v1.restored'), isNull);
      }
      expect(db.getString('studio.lastProject.v1'), isNull);
    },
  );
  test(
    'imported folder identity survives refused restore and native reopen',
    () async {
      const root = '/fixture/existing-flutter';
      final id = InspectedFolderStore.workspaceId(root);
      await InspectedFolderStore(db).save(root);
      await expectLater(
        PortableWorkspaceRestore(db)
            .restore(id: id, name: 'Collision', encoded: encoded),
        throwsStateError,
      );
      expect(db.getString('studio.projects.v1'), isNull);
      expect(db.getString('studio.chat.v1.$id'), isNull);
      await PortableWorkspaceRestore(db)
          .restore(id: 'clean', name: 'Clean', encoded: encoded);
      await db.database.close();
      db = await open();
      expect(InspectedFolderStore(db).load(), [root]);
      expect(StudioStore(db).load().single.id, 'clean');
      expect(
        ConversationStore(db).load('clean').single.content,
        'Keep exact 😀',
      );
      expect(db.getString('studio.application.v1.$id'), isNull);
    },
  );
  test(
    'corrupt imported identity records remain intact after refused restore',
    () async {
      final raw = StoreRef<String, String>('records');
      for (final key in [
        InspectedFolderStore.key,
        'studio.importedPlan.v1.orphan',
      ]) {
        await raw.record(key).put(db.database, '{}');
        await db.database.close();
        db = await open();
        await expectLater(
          PortableWorkspaceRestore(db)
              .restore(id: 'orphan', name: 'Refused', encoded: encoded),
          throwsA(anything),
        );
        expect(await raw.record(key).get(db.database), '{}');
        expect(db.getString('studio.projects.v1'), isNull);
        expect(db.getString('studio.chat.v1.orphan'), isNull);
        await raw.record(key).delete(db.database);
        await db.database.close();
        db = await open();
      }
    },
  );
  test(
    'collisions corruption and invalid inputs leave existing records intact',
    () async {
      final restore = PortableWorkspaceRestore(db);
      await restore.restore(id: 'existing', name: 'First', encoded: encoded);
      final catalog = db.getString('studio.projects.v1');
      await expectLater(
        restore.restore(id: 'existing', name: 'Second', encoded: encoded),
        throwsStateError,
      );
      await db.setString('studio.chat.v1.orphan', '[]');
      await expectLater(
        restore.restore(id: 'orphan', name: 'Second', encoded: encoded),
        throwsStateError,
      );
      await expectLater(
        restore.restore(id: '../bad', name: 'Second', encoded: encoded),
        throwsFormatException,
      );
      await expectLater(
        restore.restore(id: 'unused', name: '', encoded: encoded),
        throwsFormatException,
      );
      await expectLater(
        restore.restore(id: 'unused', name: 'Second', encoded: '{}'),
        throwsFormatException,
      );
      expect(db.getString('studio.projects.v1'), catalog);
      expect(db.getString('studio.chat.v1.unused'), isNull);
    },
  );
  test(
    'concurrent catalog updates refuse stale publication; empty board loads',
    () async {
      final empty = PortableProjectArchive(
        requirements: RequirementsBoard(),
        messages: const [],
      ).encode();
      final restore = PortableWorkspaceRestore(db);
      final results = await Future.wait([
        restore
            .restore(id: 'one', name: 'One', encoded: empty)
            .then((_) => true, onError: (_) => false),
        restore
            .restore(id: 'two', name: 'Two', encoded: empty)
            .then((_) => true, onError: (_) => false),
      ]);
      expect(results.where((r) => r).length, 1);
      final project = StudioStore(db).load().single;
      expect(RequirementsStore(db).load(project.id).revision, 0);
      expect(db.getString('studio.requirements.v1.${project.id}'), isNull);
    },
  );
  test(
    'copy survives native reopen without project or consent writes',
    () async {
      await PortableArchiveStore(db).restoreCopy('copy-1', encoded);
      await db.database.close();
      db = await open();
      final store = PortableArchiveStore(db);
      expect(store.load('copy-1')!.encode(), encoded);
      for (final key in [
        'studio.projects.v1',
        'studio.chat.v1.copy-1',
        'studio.requirements.v1.copy-1',
        'studio.planApproval.v1.copy-1',
        'studio.localModel.v1',
      ]) {
        expect(db.getString(key), isNull);
      }
      await expectLater(store.restoreCopy('copy-1', encoded), throwsStateError);
      expect(store.load('copy-1')!.encode(), encoded);
    },
  );
  test(
    'ambiguous archives never publish copies or workspace records',
    () async {
      final ambiguous = encoded.replaceFirst(
        '"revision":7',
        '"revision":8,"revision":7',
      );
      await PortableArchiveStore(db).restoreCopy('healthy', encoded);
      for (final raw in [
        ambiguous,
        encoded.replaceFirst('"content":', r'"co\u006etent":"lost","content":'),
      ]) {
        await expectLater(
          PortableArchiveStore(db).restoreCopy('invalid', raw),
          throwsFormatException,
        );
        await expectLater(
          PortableWorkspaceRestore(db)
              .restore(id: 'invalid', name: 'Invalid', encoded: raw),
          throwsFormatException,
        );
      }
      expect(db.getString('studio.projects.v1'), isNull);
      expect(db.getString('studio.archive.v1.invalid'), isNull);
      expect(db.getString('studio.chat.v1.invalid'), isNull);
      expect(db.getString('studio.requirements.v1.invalid'), isNull);
      expect(PortableArchiveStore(db).load('healthy')!.encode(), encoded);

      final records = StoreRef<String, String>('records');
      await records
          .record('studio.archive.v1.ambiguous')
          .put(db.database, ambiguous);
      await db.database.close();
      db = await open();
      expect(
        () => PortableArchiveStore(db).load('ambiguous'),
        throwsFormatException,
      );
      await expectLater(
        PortableArchiveStore(db).restoreCopy('ambiguous', encoded),
        throwsFormatException,
      );
      expect(
        await records.record('studio.archive.v1.ambiguous').get(db.database),
        ambiguous,
      );
      expect(PortableArchiveStore(db).load('healthy')!.encode(), encoded);
    },
  );

  test('concurrent copies cannot replace the same destination', () async {
    final results = await Future.wait([
      for (var i = 0; i < 2; i++)
        PortableArchiveStore(db)
            .restoreCopy('same', encoded)
            .then((_) => true, onError: (Object _) => false),
    ]);
    expect(results.where((success) => success).length, 1);
    expect(PortableArchiveStore(db).load('same')!.encode(), encoded);
  });
  test(
    'invalid input and failed transaction leave destination absent',
    () async {
      final store = PortableArchiveStore(db);
      await expectLater(
        store.restoreCopy('invalid', '{}'),
        throwsFormatException,
      );
      await expectLater(
        store.restoreCopy('../escape', encoded),
        throwsFormatException,
      );
      expect(store.load('invalid'), isNull);
      await db.database.close();
      await expectLater(
        store.restoreCopy('failed', encoded),
        throwsA(anything),
      );
      expect(db.getString(PortableArchiveStore.key('failed')), isNull);
    },
  );
  test('corrupt archive retained and isolated across reopen', () async {
    final records = StoreRef<String, String>('records');
    await records
        .record(PortableArchiveStore.key('damaged'))
        .put(db.database, '{}');
    await db.database.close();
    db = await open();
    final store = PortableArchiveStore(db);
    expect(() => store.load('damaged'), throwsFormatException);
    await expectLater(
      store.restoreCopy('damaged', encoded),
      throwsFormatException,
    );
    expect(
      await records
          .record(PortableArchiveStore.key('damaged'))
          .get(db.database),
      '{}',
    );
    await store.restoreCopy('healthy', encoded);
    expect(store.load('healthy')!.encode(), encoded);
  });
}
