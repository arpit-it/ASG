// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:io';
import 'dart:convert';

import 'package:asg/controllers/imported_source_baseline_controller.dart';
import 'package:asg/models/imported_source_context.dart';
import 'package:asg/models/imported_plan.dart';
import 'package:asg/models/imported_source_proposal.dart';
import 'package:asg/models/imported_source_proposal_record.dart';
import 'package:asg/models/project_inspection.dart';
import 'package:asg/models/project_source_observation.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/project_source_host_native.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/runtime_setup_store.dart';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/imported_source_baseline_store.dart';
import 'package:asg/services/imported_source_proposal_store.dart';

import 'imported_source_baseline_controller_test.dart' show baselineRecords;
import 'imported_source_baseline_test.dart' show baselineSaved;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('selection is immutable, read-only and does not require current plan approval', () async {
    final saved = baselineSaved(), r = await baselineRecords(baselineSaved());
    final store = ImportedSourceBaselineStore(r),
        before = Map<String, String>.of(r.values);
    final selection = store.prepare(saved);
    expect(selection.inputs.length, 5);
    expect(() => selection.inputs.clear(), throwsUnsupportedError);
    expect(
      () => selection.request.selectedPaths.clear(),
      throwsUnsupportedError,
    );
    await store.verify(selection, () {});
    expect(r.values, before);
    expect(r.updatesSeen, everyElement(isEmpty));
  });
  test('native durable read fences reject every changed key despite unchanged session cache', () async {
    final temp = await Directory.systemTemp.createTemp('asg-baseline-fences-');
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${temp.path}/records.db');
    try {
      final saved = baselineSaved(),
          seed = await baselineRecords(baselineSaved()),
          records = await StudioDatabase.migrate(db, prefs);
      for (final e in seed.values.entries) {
        await records.setString(e.key, e.value);
      }
      final store = ImportedSourceBaselineStore(records),
          selection = store.prepare(saved);
      await store.verify(selection, () {});
      final rows = StoreRef<String, String>('records');
      for (final e in selection.inputs.entries) {
        await rows
            .record(e.key)
            .put(db, e.value == null ? 'synthetic changed' : '${e.value} ');
        expect(records.getString(e.key), e.value);
        await expectLater(store.verify(selection, () {}), throwsStateError);
        if (e.value == null) {
          await rows.record(e.key).delete(db);
        } else {
          await rows.record(e.key).put(db, e.value!);
        }
      }
      await db.close();
      db = await databaseFactoryIo.openDatabase('${temp.path}/records.db');
      final reopened = await StudioDatabase.migrate(db, prefs);
      expect(
        reopened.getString(ImportedSourceProposalStore.key(saved.root)),
        saved.encode(),
      );
    } finally {
      await db.close();
      await temp.delete(recursive: true);
    }
  });
  test('corrupt or replaced history cannot be retargeted and closed read cannot cross fence', () async {
    final saved = baselineSaved(), r = await baselineRecords(baselineSaved());
    final store = ImportedSourceBaselineStore(r),
        selection = store.prepare(saved);
    await expectLater(
      store.verify(selection, () => throw StateError('disposed')),
      throwsStateError,
    );
    expect(r.updatesSeen, isEmpty);
    r.values[ImportedSourceProposalStore.key(saved.root)] = 'private corrupt';
    expect(() => store.prepare(saved), throwsStateError);
  });
  test(
    'actual Mac baseline flow matches changes and refuses without modifying saved app records',
    () async {
      const python =
          '/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12';
      expect(await File(python).exists(), true);
      final base = await Directory.systemTemp.createTemp('asg-baseline-app-');
      final project = await Directory('${base.path}/project').create();
      final root = await project.resolveSymbolicLinks();
      final first = File('$root/lib/main.dart'),
          peer = File('$root/test/peer.dart');
      await first.parent.create(recursive: true);
      await peer.parent.create(recursive: true);
      await first.writeAsBytes(utf8.encode('\ufeff// café\r\n'));
      await peer.writeAsString('// peer\r\n');
      final initial = NativeProjectSourceHost();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = await databaseFactoryIo.openDatabase(
        '${base.path}/records.db',
      );
      ImportedSourceBaselineController? controller;
      try {
        final paths = ['lib/main.dart', 'test/peer.dart'];
        final request = ProjectSourceReadRequest(
          root: root,
          python: python,
          selectedPaths: paths,
        );
        final observation = await initial.inspect(request);
        await initial.dispose();
        final context = ImportedSourceContext.capture(
          inspection: ProjectInspection(
            root: root,
            packageName: 'native_baseline_flow',
            dartSdk: '^3.0.0',
            runners: ['web'],
          ),
          requirements: RequirementsBoard(),
          request: request,
          observation: observation,
        );
        final plan = ImportedPlan(
          text: 'Synthetic historical review',
          context: context.recordJson,
          approved: true,
          recordedAt: DateTime.utc(2026),
        );
        final saved = ImportedSourceProposalRecord.create(
          context: context,
          plan: plan,
          proposal: ImportedSourceProposal.create(
            context: context,
            plan: plan,
            path: 'lib/main.dart',
            replacement: '// proposed\n',
          ),
          recordedAt: DateTime.utc(2026),
        );
        final records = await StudioDatabase.migrate(db, prefs);
        await InspectedFolderStore(records).save(root);
        await RuntimeSetupStore(records)
            .save(const RuntimeSetup(python: python));
        await records.setString(
          ImportedSourceProposalStore.key(root),
          saved.encode(),
        );
        final rows = StoreRef<String, String>('records');
        final before = {
          for (final row in await rows.find(db)) row.key: row.value,
        };
        final c = ImportedSourceBaselineController(
          saved: saved,
          store: ImportedSourceBaselineStore(records),
        );
        controller = c;
        var confirmations = 0;
        Future<bool> confirm(ProjectSourceReadRequest value) async {
          confirmations++;
          expect(value.root, root);
          expect(value.selectedPaths, paths);
          return true;
        }

        await c.recheck(confirm: confirm);
        expect(c.error, isNull);
        expect(c.comparison!.matched, true);
        await peer.writeAsString('// changed peer\n');
        await c.recheck(confirm: confirm);
        expect(c.error, isNull);
        expect(c.comparison!.changedPaths, ['test/peer.dart']);
        final changed = c.comparison!;
        await peer.delete();
        await c.recheck(confirm: confirm);
        expect(c.refusal!.reason, 'source_missing');
        expect(c.comparison, same(changed));
        expect(c.stale, true);
        expect({
          for (final row in await rows.find(db)) row.key: row.value,
        }, before);
        expect(
          records.getString(ImportedSourceProposalStore.key(root)),
          saved.encode(),
        );
        expect(await first.readAsBytes(), utf8.encode('\ufeff// café\r\n'));
        expect(c.store.readOwned, false);
        expect(confirmations, 3);
      } finally {
        controller?.dispose();
        await initial.dispose();
        await db.close();
        await base.delete(recursive: true);
      }
    },
    skip: !Platform.isMacOS
        ? 'Known Mac Python and contained reader required; no other-host claim.'
        : false,
  );
}
