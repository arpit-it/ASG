import 'dart:async';

import 'package:asg/controllers/imported_plan_controller.dart';
import 'package:asg/models/project_inspection.dart';
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
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
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

void main() {
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
    expect(missing.error, contains('missing'));
    missing.dispose();
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
    expect(find.text('Approved for current planning context'), findsOneWidget);
    await tester.ensureVisible(find.text('Withdraw approval'));
    await tester.tap(find.text('Withdraw approval'));
    await tester.pumpAndSettle();
    expect(c.approved, isFalse);
    expect(tester.takeException(), isNull);
  });
}
