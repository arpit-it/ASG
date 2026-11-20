// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:io';

import 'package:asg/services/studio_database.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:asg/controllers/imported_plan_controller.dart';
import 'package:asg/models/project_inspection.dart';
import 'package:asg/models/imported_document_context.dart';
import 'package:asg/models/project_instruction_observation.dart';
import 'package:crypto/crypto.dart';

import 'dart:convert';

import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/views/imported_plan_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Records implements RecordStorage {
  final values = <String, String>{};
  bool fail = false;
  String? failure, writeFailure;
  int writes = 0;
  @override
  String? getString(String key) {
    if (failure != null) throw StateError(failure!);
    return values[key];
  }

  @override
  Future<bool> setString(String key, String value) async {
    if (writeFailure != null) throw StateError(writeFailure!);
    writes++;
    if (fail) return false;
    values[key] = value;
    return true;
  }
}

ProjectInspection finding({String sdk = '^3.0.0'}) => ProjectInspection(
  root: '/project',
  packageName: 'example',
  dartSdk: sdk,
  runners: ['web'],
);
Future<ImportedPlanController> create(
  Records records, {
  Future<ProjectInspection> Function(String)? inspect,
}) async {
  await InspectedFolderStore(records).save('/project');
  final c = ImportedPlanController(
    '/project',
    ImportedPlanStore(records),
    inspect: inspect ?? (_) async => finding(),
  );
  await c.load();
  return c;
}

class PendingPlanRecords extends Records {
  Completer<void>? gate;
  @override
  Future<bool> setString(String key, String value) async {
    if (key.startsWith('studio.importedPlan.v1.')) await gate?.future;
    return super.setString(key, value);
  }
}

ImportedDocumentContext capturedPlan({
  String text = 'Captured untrusted instructions',
  ProjectInspection? inspection,
  RequirementsBoard? board,
}) {
  final data = utf8.encode(text), metadata = inspection ?? finding();
  return ImportedDocumentContext.capture(
    inspection: metadata,
    requirements: board ?? RequirementsBoard(),
    request: ProjectInstructionReadRequest(
      root: metadata.root,
      python: '/python',
      selectedPaths: ['AGENTS.md'],
    ),
    observation: ProjectInstructionObservation.fromJson(
      jsonEncode({
        'version': 1,
        'scope': 'project-instruction-documents',
        'status': 'observed',
        'reason': null,
        'source_verified': false,
        'selected_paths': ['AGENTS.md'],
        'documents': [
          {
            'path': 'AGENTS.md',
            'byte_length': data.length,
            'sha256': sha256.convert(data).toString(),
            'content_base64': base64Encode(data),
          },
        ],
      }),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('default planning uses only the confirmed workspace snapshot and app records', () async {
    final records = Records();
    await InspectedFolderStore(records).save('/project');
    final c = ImportedPlanController(
      '/project',
      ImportedPlanStore(records),
      inspection: finding(),
    );
    await c.load();
    expect(c.error, isNull);
    await c.saveDraft('Review captured metadata only');
    await c.decide(true);
    expect(c.approved, isTrue);
    expect(c.plan!.context, contains('example'));
    c.dispose();
  });
  test(
    'missing or different-root planning snapshot fails closed without writes',
    () async {
      final records = Records();
      await InspectedFolderStore(records).save('/project');
      final before = Map<String, String>.of(records.values);
      final other = ProjectInspection(
        root: '/other',
        packageName: 'other',
        dartSdk: '^3.0.0',
        runners: [],
      );
      for (final inspection in [null, other]) {
        final c = ImportedPlanController(
          '/project',
          ImportedPlanStore(records),
          inspection: inspection,
        );
        await c.load();
        await c.saveDraft('No implicit helper launch');
        expect(c.error, isNotNull);
        expect(c.approved, isFalse);
        expect(records.values, before);
        c.dispose();
      }
    },
  );
  test(
    'private write and corrupt JSON failures retain bytes and recover',
    () async {
      final records = Records();
      final c = await create(records);
      await c.saveDraft('Original');
      final saved = Map<String, String>.of(records.values);
      final plan = c.plan;
      records.writeFailure = 'PRIVATE_WRITE /private/secret';
      await c.saveDraft('Changed');
      expect(c.error, isNot(contains('PRIVATE_WRITE')));
      expect(c.error, isNot(contains('/private/secret')));
      expect(c.plan, same(plan));
      expect(records.values, saved);
      records.writeFailure = null;
      await c.saveDraft('Changed');
      expect(c.error, isNull);
      final key = ImportedPlanStore.key('/project');
      records.values[key] = '{"text":"PRIVATE_JSON",';
      final corrupt = Map<String, String>.of(records.values);
      final writes = records.writes;
      await c.load();
      expect(c.error, isNot(contains('PRIVATE_JSON')));
      expect(c.approved, isFalse);
      await c.saveDraft('Do not replace corrupt data');
      expect(c.error, isNot(contains('PRIVATE_JSON')));
      expect(records.values, corrupt);
      expect(records.writes, writes);
      records.values[key] = saved[key]!;
      await c.load();
      expect(c.plan!.text, 'Original');
      expect(c.error, isNull);
      c.dispose();
    },
  );
  test(
    'disposed inspection failure emits no late error or notification',
    () async {
      final records = Records();
      final pending = Completer<ProjectInspection>();
      final c = ImportedPlanController(
        '/project',
        ImportedPlanStore(records),
        inspect: (_) => pending.future,
      );
      var notifications = 0;
      c.addListener(() => notifications++);
      final load = c.load();
      c.dispose();
      final before = notifications;
      pending.completeError(StateError('PRIVATE_LATE'));
      await load;
      expect(c.error, isNull);
      expect(notifications, before);
      expect(records.writes, 0);
    },
  );
  test(
    'private read errors preserve plan and recover approval on reload',
    () async {
      final records = Records();
      final c = await create(records);
      await c.saveDraft('Original plan');
      await c.decide(true);
      final saved = Map<String, String>.of(records.values);
      final plan = c.plan;
      records.failure = 'PRIVATE_PROMPT /private/secret';
      for (var i = 0; i < 2; i++) {
        await c.load();
        expect(c.error, isNot(contains('PRIVATE_PROMPT')));
        expect(c.error, isNot(contains('/private/secret')));
        expect(c.plan, same(plan));
        expect(c.approved, isFalse);
        expect(c.busy, isFalse);
      }
      expect(records.values, saved);
      records.failure = null;
      await c.load();
      expect(c.error, isNull);
      expect(c.approved, isTrue);
      c.dispose();
    },
  );
  test(
    'private inspection failures during save retain plan and retry',
    () async {
      final records = Records();
      var fail = false;
      final c = await create(
        records,
        inspect: (_) async {
          if (fail) throw StateError('PRIVATE_PROMPT /private/secret');
          return finding();
        },
      );
      await c.saveDraft('Original');
      final saved = Map<String, String>.of(records.values);
      final plan = c.plan;
      fail = true;
      await c.saveDraft('Changed');
      expect(c.error, isNot(contains('PRIVATE_PROMPT')));
      expect(c.error, isNot(contains('/private/secret')));
      expect(c.plan, same(plan));
      expect(c.approved, isFalse);
      expect(records.values, saved);
      fail = false;
      await c.saveDraft('Changed');
      expect(c.error, isNull);
      final reopened = await create(records);
      expect(reopened.plan!.text, 'Changed');
      c.dispose();
      reopened.dispose();
    },
  );
  test(
    'reopen retains plan and consent; changed requirements invalidate',
    () async {
      final records = Records();
      final c = await create(records);
      await c.saveDraft('Implement R1');
      expect(c.approved, isFalse);
      await c.decide(true);
      expect(c.approved, isTrue);
      c.dispose();
      final reopened = await create(records);
      expect(reopened.approved, isTrue);
      final store = RequirementsStore(records);
      final id = InspectedFolderStore.workspaceId('/project');
      await store.save(
        id,
        store.load(id),
        RequirementsBoard(
          requirements: [
            ProjectRequirement(
              id: 'R1',
              title: 'New scope',
              acceptance: 'Tests pass',
            ),
          ],
        ),
      );
      expect(reopened.approved, isFalse);
      final before = records.values[ImportedPlanStore.key('/project')];
      await reopened.decide(true);
      expect(reopened.error, contains('current draft'));
      expect(records.values[ImportedPlanStore.key('/project')], before);
      await reopened.load();
      await reopened.saveDraft('Updated plan');
      await reopened.decide(true);
      expect(reopened.approved, isTrue);
      await reopened.decide(false);
      expect(reopened.approved, isFalse);
      expect(ImportedPlanStore(records).load('/other'), isNull);
      reopened.dispose();
    },
  );
  test(
    'metadata changes, failed writes, corrupt data and invalid drafts',
    () async {
      final records = Records();
      var sdk = '^3.0.0';
      final c = await create(records, inspect: (_) async => finding(sdk: sdk));
      await c.saveDraft(' ');
      expect(c.error, isNotNull);
      expect(c.plan, isNull);
      await c.load();
      records.fail = true;
      await c.saveDraft('Plan');
      expect(c.error, contains('could not be saved'));
      expect(c.plan, isNull);
      records.fail = false;
      await c.load();
      await c.saveDraft('Plan');
      await c.decide(true);
      sdk = '^4.0.0';
      await c.load();
      expect(c.current, isFalse);
      records.values[ImportedPlanStore.key('/project')] = 'broken';
      await c.load();
      await c.saveDraft('Overwrite');
      expect(records.values[ImportedPlanStore.key('/project')], 'broken');
      c.dispose();
    },
  );
  test('fresh inspection, duplicates and disposal refuse late save', () async {
    final records = Records();
    var calls = 0;
    Completer<ProjectInspection>? pending;
    final c = await create(
      records,
      inspect: (_) async {
        calls++;
        return pending == null ? finding() : pending.future;
      },
    );
    pending = Completer<ProjectInspection>();
    final save = c.saveDraft('Plan');
    await c.saveDraft('Duplicate');
    expect(calls, 2);
    c.dispose();
    pending.complete(finding());
    await save;
    expect(ImportedPlanStore(records).load('/project'), isNull);
    final missing = await create(
      records,
      inspect: (_) async => throw StateError('missing folder'),
    );
    await missing.saveDraft('Plan');
    expect(missing.error, contains('could not be saved'));
    missing.dispose();
  });
  testWidgets('failed save retries the unchanged editor draft without reload', (
    tester,
  ) async {
    final records = Records();
    final c = await create(records);
    await tester.pumpWidget(
      MaterialApp(home: ImportedPlanScreen(controller: c)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Keep this unsaved plan');
    records.fail = true;
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    expect(c.plan, isNull);
    expect(c.error, contains('could not be saved'));
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Keep this unsaved plan',
    );
    records.fail = false;
    await tester.ensureVisible(find.text('Reload plan'));
    await tester.tap(find.text('Reload plan'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Keep this unsaved plan',
    );
    await tester.ensureVisible(find.text('Save draft'));
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    expect(c.plan!.text, 'Keep this unsaved plan');
    await tester.enterText(find.byType(TextField), 'Direct retry draft');
    records.fail = true;
    await tester.ensureVisible(find.text('Save draft'));
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    records.fail = false;
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    expect(c.plan!.text, 'Direct retry draft');
    expect(c.error, isNull);
  });
  testWidgets('initial inspection recovery preserves a newly typed draft', (
    tester,
  ) async {
    final records = Records();
    await InspectedFolderStore(records).save('/project');
    var missing = true;
    final c = ImportedPlanController(
      '/project',
      ImportedPlanStore(records),
      inspect: (_) async {
        if (missing) throw StateError('missing folder');
        return finding();
      },
    );
    await tester.pumpWidget(
      MaterialApp(home: ImportedPlanScreen(controller: c)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      'Typed during initial failure',
    );
    missing = false;
    await tester.ensureVisible(find.text('Reload plan'));
    await tester.tap(find.text('Reload plan'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      'Typed during initial failure',
    );
    await tester.ensureVisible(find.text('Save draft'));
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    expect(c.plan!.text, 'Typed during initial failure');
  });
  testWidgets('visible draft, approval, reopen and withdrawal', (tester) async {
    final records = Records();
    var c = await create(records);
    await tester.pumpWidget(
      MaterialApp(home: ImportedPlanScreen(controller: c)),
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Review requirements');
    await tester.tap(find.text('Save draft'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Approve saved plan'));
    await tester.tap(find.text('Approve saved plan'));
    await tester.pumpAndSettle();
    expect(c.approved, isTrue);
    await tester.pumpWidget(const SizedBox());
    c = await create(records);
    await tester.pumpWidget(
      MaterialApp(home: ImportedPlanScreen(controller: c)),
    );
    await tester.pumpAndSettle();
    expect(find.text('Approved for captured planning context'), findsOneWidget);
    await tester.ensureVisible(find.text('Withdraw approval'));
    await tester.tap(find.text('Withdraw approval'));
    await tester.pumpAndSettle();
    expect(c.approved, isFalse);
    expect(tester.takeException(), isNull);
  });
  test('captured plan preserves v1 record shape and legacy text without silently reviving approval', () async {
    final records = Records();
    await InspectedFolderStore(records).save('/project');
    final legacy = ImportedPlanController(
      '/project',
      ImportedPlanStore(records),
      inspection: finding(),
    );
    await legacy.load();
    await legacy.saveDraft('Existing authored plan');
    await legacy.decide(true);
    final key = ImportedPlanStore.key('/project'),
        before = records.values[key]!,
        keys = (jsonDecode(records.values[key]!) as Map).keys.toSet();
    final capture = capturedPlan(),
        store = ImportedPlanStore(records, capturedDocuments: capturedPlan());
    final c = ImportedPlanController('/project', store, inspection: finding());
    await c.load();
    expect(c.plan!.text, 'Existing authored plan');
    expect(c.approved, false);
    expect(records.values[key], before);
    await c.saveDraft('Review selected captured documents');
    await c.decide(true);
    expect(c.approved, true);
    expect(c.plan!.context, capture.recordJson);
    expect((jsonDecode(records.values[key]!) as Map).keys.toSet(), keys);
    final saved = records.values[key];
    final reopened = ImportedPlanController(
      '/project',
      ImportedPlanStore(records, capturedDocuments: capturedPlan()),
      inspection: finding(),
    );
    await reopened.load();
    expect(reopened.approved, true);
    expect(records.values[key], saved);
    final metadataOnly = ImportedPlanController(
      '/project',
      ImportedPlanStore(records),
      inspection: finding(),
    );
    await metadataOnly.load();
    expect(metadataOnly.approved, false);
    expect(metadataOnly.plan!.text, c.plan!.text);
    expect(records.values[key], saved);
    legacy.dispose();
    c.dispose();
    reopened.dispose();
    metadataOnly.dispose();
  });
  test('changed requirements or document capture invalidates approval and preserves last record', () async {
    final records = Records();
    await InspectedFolderStore(records).save('/project');
    final c = ImportedPlanController(
      '/project',
      ImportedPlanStore(records, capturedDocuments: capturedPlan()),
      inspection: finding(),
    );
    await c.load();
    await c.saveDraft('Review capture');
    await c.decide(true);
    final key = ImportedPlanStore.key('/project'), saved = records.values[key];
    final next = ImportedPlanController(
      '/project',
      ImportedPlanStore(
        records,
        capturedDocuments: capturedPlan(text: 'changed'),
      ),
      inspection: finding(),
    );
    await next.load();
    expect(next.approved, false);
    final requirements = RequirementsStore(records),
        id = InspectedFolderStore.workspaceId('/project');
    await requirements.save(id, requirements.load(id), RequirementsBoard());
    expect(c.approved, false);
    await c.decide(true);
    expect(c.error, isNotNull);
    expect(records.values[key], saved);
    await c.saveDraft('Unsaved after requirements changed');
    expect(records.values[key], saved);
    c.dispose();
    next.dispose();
  });
  test('captured context mismatch and failed writes retain bytes and allow an unchanged retry', () async {
    final records = Records();
    await InspectedFolderStore(records).save('/project');
    final c = ImportedPlanController(
      '/project',
      ImportedPlanStore(records, capturedDocuments: capturedPlan()),
      inspection: finding(),
    );
    await c.load();
    await c.saveDraft('Old text');
    final key = ImportedPlanStore.key('/project'), saved = records.values[key];
    records.fail = true;
    await c.saveDraft('New text');
    expect(records.values[key], saved);
    expect(c.approved, false);
    records.fail = false;
    await c.saveDraft('New text');
    expect(c.plan!.text, 'New text');
    final wrong = ImportedPlanStore(
      records,
      capturedDocuments: capturedPlan(
        inspection: ProjectInspection(
          root: '/other',
          packageName: 'fixture',
          dartSdk: '^3.0.0',
          runners: ['web'],
        ),
      ),
    );
    expect(() => wrong.context(finding()), throwsStateError);
    c.dispose();
  });
  test(
    'concurrent captured-plan editors preserve the first committed record',
    () async {
      final records = Records();
      await InspectedFolderStore(records).save('/project');
      final first = ImportedPlanController(
        '/project',
        ImportedPlanStore(records, capturedDocuments: capturedPlan()),
        inspection: finding(),
      );
      final second = ImportedPlanController(
        '/project',
        ImportedPlanStore(records, capturedDocuments: capturedPlan()),
        inspection: finding(),
      );
      await first.load();
      await second.load();
      await first.saveDraft('First committed');
      final saved = records.values[ImportedPlanStore.key('/project')];
      await second.saveDraft('Stale second editor');
      expect(second.error, isNotNull);
      expect(records.values[ImportedPlanStore.key('/project')], saved);
      first.dispose();
      second.dispose();
    },
  );
  test(
    'disposal after snapshot await prevents late planning record access',
    () async {
      final records = Records();
      await InspectedFolderStore(records).save('/project');
      final pending = Completer<ProjectInspection>();
      final c = ImportedPlanController(
        '/project',
        ImportedPlanStore(records, capturedDocuments: capturedPlan()),
        inspect: (_) => pending.future,
      );
      final load = c.load();
      c.dispose();
      records.failure = 'private-sentinel';
      pending.complete(finding());
      await load;
      expect(c.plan, isNull);
      expect(c.error, isNull);
    },
  );
  test('requirements changing during a pending approval write never become active consent', () async {
    final records = PendingPlanRecords();
    await InspectedFolderStore(records).save('/project');
    final c = ImportedPlanController(
      '/project',
      ImportedPlanStore(records, capturedDocuments: capturedPlan()),
      inspection: finding(),
    );
    await c.load();
    await c.saveDraft('Historical snapshot review');
    records.gate = Completer<void>();
    final pending = c.decide(true);
    await Future<void>.delayed(Duration.zero);
    final requirements = RequirementsStore(records),
        id = InspectedFolderStore.workspaceId('/project');
    await requirements.save(id, requirements.load(id), RequirementsBoard());
    records.gate!.complete();
    await pending;
    expect(c.approved, false);
    expect(c.current, false);
    final nextCapture = capturedPlan(board: requirements.load(id));
    final next = ImportedPlanController(
      '/project',
      ImportedPlanStore(records, capturedDocuments: nextCapture),
      inspection: finding(),
    );
    await next.load();
    expect(next.plan!.text, 'Historical snapshot review');
    expect(next.approved, false);
    c.dispose();
    next.dispose();
  });
  test('synchronous disposal at busy notification prevents injected inspection and writes', () async {
    final records = Records();
    await InspectedFolderStore(records).save('/project');
    var inspected = 0;
    final c = ImportedPlanController(
      '/project',
      ImportedPlanStore(records, capturedDocuments: capturedPlan()),
      inspect: (_) async {
        inspected++;
        return finding();
      },
    );
    c.addListener(c.dispose);
    final writes = records.writes;
    await c.load();
    expect(inspected, 0);
    expect(records.writes, writes);
    expect(c.current, false);
  });
  testWidgets(
    'replaced plan controller drops pending old hydration and clears old editor text',
    (tester) async {
      final records = Records();
      await InspectedFolderStore(records).save('/project');
      await InspectedFolderStore(records).save('/other');
      final other = ProjectInspection(
        root: '/other',
        packageName: 'other',
        dartSdk: '^3.0.0',
        runners: ['web'],
      );
      final seed = ImportedPlanController(
        '/other',
        ImportedPlanStore(records),
        inspection: other,
      );
      await seed.load();
      await seed.saveDraft('Other workspace plan');
      seed.dispose();
      final pending = Completer<ProjectInspection>();
      final old = ImportedPlanController(
        '/project',
        ImportedPlanStore(records),
        inspect: (_) => pending.future,
      );
      await tester.pumpWidget(
        MaterialApp(home: ImportedPlanScreen(controller: old)),
      );
      await tester.pump();
      final next = ImportedPlanController(
        '/other',
        ImportedPlanStore(records),
        inspection: other,
      );
      await tester.pumpWidget(
        MaterialApp(home: ImportedPlanScreen(controller: next)),
      );
      await tester.pumpAndSettle();
      pending.complete(finding());
      await tester.pumpAndSettle();
      expect(old.isDisposed, true);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Other workspace plan',
      );
      expect(next.root, '/other');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  test('captured plan survives an actual native database close and reopen unchanged', () async {
    final root = await Directory.systemTemp.createTemp('asg-captured-plan-db-');
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    try {
      final records = await StudioDatabase.migrate(db, preferences);
      await InspectedFolderStore(records).save('/project');
      final c = ImportedPlanController(
        '/project',
        ImportedPlanStore(
          records,
          capturedDocuments: capturedPlan(text: '\ufeffcafé\r\nCaptured data'),
        ),
        inspection: finding(),
      );
      await c.load();
      await c.saveDraft('Durable captured plan');
      await c.decide(true);
      expect(c.approved, true);
      final key = ImportedPlanStore.key('/project'),
          raw = records.getString(key);
      c.dispose();
      await db.close();
      db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      final reopened = await StudioDatabase.migrate(db, preferences);
      final next = ImportedPlanController(
        '/project',
        ImportedPlanStore(
          reopened,
          capturedDocuments: capturedPlan(text: '\ufeffcafé\r\nCaptured data'),
        ),
        inspection: finding(),
      );
      await next.load();
      expect(next.approved, true);
      expect(next.plan!.text, 'Durable captured plan');
      expect(
        next.plan!.context,
        capturedPlan(text: '\ufeffcafé\r\nCaptured data').recordJson,
      );
      expect(reopened.getString(key), raw);
      next.dispose();
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
  test('production conditional save rejects changed durable inputs despite a stale session snapshot', () async {
    final root = await Directory.systemTemp.createTemp(
      'asg-captured-plan-cas-',
    );
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    try {
      final records = await StudioDatabase.migrate(db, preferences);
      await InspectedFolderStore(records).save('/project');
      final c = ImportedPlanController(
        '/project',
        ImportedPlanStore(records, capturedDocuments: capturedPlan()),
        inspection: finding(),
      );
      await c.load();
      await c.saveDraft('Last working draft');
      final key = ImportedPlanStore.key('/project'),
          raw = records.getString(key);
      final requirementKey = RequirementsStore.key(
        InspectedFolderStore.workspaceId('/project'),
      );
      final rows = StoreRef<String, String>('records');
      await rows
          .record(requirementKey)
          .put(db, jsonEncode(RequirementsBoard(revision: 1).toJson()));
      expect(records.getString(requirementKey), isNull);
      await c.decide(true);
      expect(c.error, isNotNull);
      expect(c.approved, false);
      expect(await rows.record(key).get(db), raw);
      expect(records.getString(key), raw);
      c.dispose();
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
