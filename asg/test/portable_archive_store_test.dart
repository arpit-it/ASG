import 'dart:io';

import 'package:asg/services/portable_workspace_restore.dart';
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

void main() {
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
