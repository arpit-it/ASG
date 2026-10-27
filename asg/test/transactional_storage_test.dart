// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'source_generation_controller_test.dart' show generated;

import 'package:asg/controllers/app_workspace_controller.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

const project = StudioProject(
  id: 'p',
  name: 'Demo',
  description: 'tasks',
  type: 'Flutter',
  platforms: ['macOS'],
  location: '',
);
const definition = AppDefinition(
  title: 'Demo',
  theme: 'green',
  elements: [
    AppElement(
      id: 'counter',
      kind: ElementKind.counter,
      label: 'Count',
      value: '7',
    ),
    AppElement(
      id: 'tasks',
      kind: ElementKind.taskList,
      label: 'Tasks',
      items: ['One', 'Two'],
      completed: [1],
    ),
    AppElement(
      id: 'notes',
      kind: ElementKind.notes,
      label: 'Notes',
      value: 'Remember',
    ),
  ],
);
final snapshot = jsonEncode({
  'definition': definition.toJson(),
  'messages': <Object>[],
  'revision': 3,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late String path;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    temp = await Directory.systemTemp.createTemp('asg-storage-test-');
    path = '${temp.path}/test.db';
  });
  tearDown(() async => temp.delete(recursive: true));

  test('conditional promotion commits both pointers atomically and refuses stale inputs', () async {
    final db = await databaseFactoryIo.openDatabase(path);
    final prefs = await SharedPreferences.getInstance();
    var records = await StudioDatabase.migrate(db, prefs);
    final old = jsonEncode(generated.toJson());
    final next = jsonEncode({
      ...generated.toJson(),
      'directory': '/candidate',
      'confinementVersion': 1,
    });
    await records.setString('studio.generation.v1.p', old);
    await records.setString('studio.lastProject.v1', 'approval-context');
    final expected = {
      'studio.generation.v1.p': old,
      'studio.lastProject.v1': 'approval-context',
    };
    final updates = {
      'studio.generation.v1.p': next,
      'studio.generationPrevious.v1.p': old,
    };
    await expectLater(
      records.commitRecords(
        expected: expected,
        updates: updates,
        authorize: () => throw StateError('cancelled'),
      ),
      throwsStateError,
    );
    expect(records.getString('studio.generation.v1.p'), old);
    expect(records.getString('studio.generationPrevious.v1.p'), isNull);
    await records.setString('studio.lastProject.v1', 'withdrawn');
    await expectLater(
      records.commitRecords(
        expected: expected,
        updates: updates,
        authorize: () {},
      ),
      throwsStateError,
    );
    expect(records.getString('studio.generation.v1.p'), old);
    await records.setString('studio.lastProject.v1', 'approval-context');
    await records.commitRecords(
      expected: expected,
      updates: updates,
      authorize: () {},
    );
    await db.close();
    final reopened = await databaseFactoryIo.openDatabase(path);
    try {
      records = await StudioDatabase.migrate(reopened, prefs);
      expect(records.getString('studio.generation.v1.p'), next);
      expect(records.getString('studio.generationPrevious.v1.p'), old);
    } finally {
      await reopened.close();
    }
  });

  test(
    'migrates all namespaces and retains originals across restart',
    () async {
      final original = <String, Object>{
        'studio.projects.v1': jsonEncode([project.toJson()]),
        'studio.chat.v1.p': '[{"role":"user","content":"Hello"}]',
        'studio.localModel.v1':
            '{"baseUrl":"http://127.0.0.1:8765/v1","model":"Qwen3.5-9B"}',
        'studio.runtimeSetup.v1': '{"python":"python3","modelPath":"/models","repository":"","downloadParent":"","revision":"main"}',
        'studio.lastProject.v1': 'p',
        'studio.application.v1.p': snapshot,
        'unrelated': 'retain',
      };
      SharedPreferences.setMockInitialValues(original);
      final prefs = await SharedPreferences.getInstance();
      var db = await databaseFactoryIo.openDatabase(
        path,
        mode: DatabaseMode.create,
      );
      var records = await StudioDatabase.migrate(db, prefs);
      for (final key in original.keys.where((k) => k.startsWith('studio.'))) {
        expect(records.getString(key), original[key]);
        expect(prefs.getString(key), original[key]);
      }
      await records.setString('studio.lastProject.v1', 'new');
      await db.close();
      db = await databaseFactoryIo.openDatabase(
        path,
        mode: DatabaseMode.create,
      );
      records = await StudioDatabase.migrate(db, prefs);
      expect(records.getString('studio.lastProject.v1'), 'new');
      final loaded = ApplicationStore(records).load(project);
      expect(loaded.revision, 3);
      expect(loaded.definition.elements[0].value, '7');
      expect(loaded.definition.elements[1].completed, [1]);
      expect(loaded.definition.elements[2].value, 'Remember');
      expect(prefs.getString('unrelated'), 'retain');
      await db.close();
    },
  );

  test(
    'interrupted migration rolls back marker and records then retries',
    () async {
      SharedPreferences.setMockInitialValues({
        'studio.application.v1.p': snapshot,
      });
      final prefs = await SharedPreferences.getInstance();
      var db = await databaseFactoryIo.openDatabase(
        path,
        mode: DatabaseMode.create,
      );
      await expectLater(
        StudioDatabase.migrate(
          db,
          prefs,
          beforeCommit: () async => throw StateError('interrupted'),
        ),
        throwsStateError,
      );
      expect(await StoreRef<String, String>('records').find(db), isEmpty);
      expect(
        await StoreRef<String, int>('metadata')
            .record('preferencesMigration')
            .get(db),
        isNull,
      );
      await db.close();
      db = await databaseFactoryIo.openDatabase(
        path,
        mode: DatabaseMode.create,
      );
      final records = await StudioDatabase.migrate(db, prefs);
      expect(records.getString('studio.application.v1.p'), snapshot);
      expect(prefs.getString('studio.application.v1.p'), snapshot);
      await db.close();
    },
  );

  test(
    'corrupt legacy data prevents migration without replacing records',
    () async {
      SharedPreferences.setMockInitialValues({
        'studio.projects.v1': 'not json',
        'studio.application.v1.p': snapshot,
      });
      final db = await databaseFactoryIo.openDatabase(
        path,
        mode: DatabaseMode.create,
      );
      final prefs = await SharedPreferences.getInstance();
      await expectLater(
        StudioDatabase.migrate(db, prefs),
        throwsFormatException,
      );
      expect(await StoreRef<String, String>('records').find(db), isEmpty);
      expect(prefs.getString('studio.projects.v1'), 'not json');
      await db.close();
    },
  );

  test(
    'invalid writes and failed disk writes preserve last committed snapshot',
    () async {
      final db = await databaseFactoryIo.openDatabase(
        path,
        mode: DatabaseMode.create,
      );
      final records = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      await records.setString('studio.application.v1.p', snapshot);
      await expectLater(
        records.setString('studio.application.v1.p', '{}'),
        throwsA(anything),
      );
      expect(records.getString('studio.application.v1.p'), snapshot);
      await db.close();
      await expectLater(
        records.setString('studio.lastProject.v1', 'failed'),
        throwsA(anything),
      );
      expect(records.getString('studio.lastProject.v1'), isNull);
      final reopened = await databaseFactoryIo.openDatabase(
        path,
        mode: DatabaseMode.create,
      );
      final restored = await StudioDatabase.migrate(
        reopened,
        await SharedPreferences.getInstance(),
      );
      expect(restored.getString('studio.application.v1.p'), snapshot);
      await reopened.close();
    },
  );

  test(
    'corrupt project record surfaces on access and is not replaced',
    () async {
      var db = await databaseFactoryIo.openDatabase(
        path,
        mode: DatabaseMode.create,
      );
      await StudioDatabase.migrate(db, await SharedPreferences.getInstance());
      await StoreRef<String, String>('records')
          .record('studio.application.v1.p')
          .put(db, 'broken');
      await db.close();
      db = await databaseFactoryIo.openDatabase(
        path,
        mode: DatabaseMode.create,
      );
      final records = await StudioDatabase.migrate(
        db,
        await SharedPreferences.getInstance(),
      );
      expect(
        () => records.getString('studio.application.v1.p'),
        throwsFormatException,
      );
      expect(
        await StoreRef<String, String>('records')
            .record('studio.application.v1.p')
            .get(db),
        'broken',
      );
      await db.close();
    },
  );

  test(
    'corrupt global records still stop startup without replacement',
    () async {
      var db = await databaseFactoryIo.openDatabase(
        path,
        mode: DatabaseMode.create,
      );
      final prefs = await SharedPreferences.getInstance();
      await StudioDatabase.migrate(db, prefs);
      final raw = StoreRef<String, String>('records')
          .record('studio.projects.v1');
      await raw.put(db, 'broken global project list');
      await db.close();
      db = await databaseFactoryIo.openDatabase(
        path,
        mode: DatabaseMode.create,
      );
      try {
        await expectLater(
          StudioDatabase.migrate(db, prefs),
          throwsFormatException,
        );
        expect(await raw.get(db), 'broken global project list');
      } finally {
        await db.close();
      }
    },
  );

  test(
    'strict native open does not replace a physically corrupt file',
    () async {
      final file = File(path);
      await file.writeAsString('damaged database\n');
      final original = await file.readAsBytes();
      await expectLater(
        databaseFactoryIo.openDatabase(path, mode: DatabaseMode.create),
        throwsA(anything),
      );
      expect(await file.readAsBytes(), original);
    },
  );

  test('controller exposes failed interaction save and retries without new revision', () async {
    final db = await databaseFactoryIo.openDatabase(
      path,
      mode: DatabaseMode.create,
    );
    final records = await StudioDatabase.migrate(
      db,
      await SharedPreferences.getInstance(),
    );
    final store = RetryStore(records);
    final controller = AppWorkspaceController(
      project,
      openStore: () async => store,
    );
    await controller.load();
    final initial = controller.definition!.toJson();
    store.fail = true;
    await controller.recordRuntimeState(definition);
    expect(controller.hasUnsavedInteractions, isTrue);
    expect(controller.error, contains('not saved'));
    expect(
      ApplicationStore(records).load(project).definition.toJson(),
      initial,
    );
    expect(await controller.apply('change theme to pink'), isFalse);
    store.fail = false;
    expect(await controller.saveInteractions(), isTrue);
    expect(controller.hasUnsavedInteractions, isFalse);
    final loaded = ApplicationStore(records).load(project);
    expect(loaded.revision, 1);
    expect(loaded.definition.toJson(), definition.toJson());
    controller.dispose();
    await db.close();
  });
}

class RetryStore extends ApplicationStore {
  RetryStore(super.records);
  bool fail = false;
  @override
  Future<void> save(String id, ApplicationSnapshot state) async {
    if (fail) throw StateError('Disk unavailable');
    await super.save(id, state);
  }
}
