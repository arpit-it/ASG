// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/controllers/imported_commit_comparison_controller.dart';
import 'package:asg/models/imported_source_context.dart';
import 'package:asg/models/imported_commit_source_observation.dart';
import 'package:asg/models/imported_source_proposal.dart';
import 'package:asg/models/imported_source_proposal_record.dart';
import 'package:asg/models/imported_plan.dart';
import 'package:asg/models/imported_commit_context.dart';
import 'package:asg/controllers/imported_plan_controller.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/models/project_inspection.dart';
import 'package:asg/models/project_source_observation.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/imported_commit_comparison_store.dart';
import 'package:asg/services/imported_source_proposal_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/project_source_host_native.dart';

import 'imported_commit_comparison_controller_test.dart' show baselineRecords;
import 'imported_source_baseline_test.dart' show baselineSaved;

/// Returned metadata belongs to this newly owned fixture only. No rolling artifact
/// is written by the regression; an explicit separate runner can retain its event.
Future<Map<String, Object?>> actualCommitComparisonFixture({
  bool exercisePlanning = false,
}) async {
  const python =
      '/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12';
  final base = await Directory.systemTemp.createTemp(
    'asg-commit-comparison-db-',
  );
  final source = await Directory('${base.path}/source').create();
  final root = await source.resolveSymbolicLinks();
  final first = File('$root/lib/main.dart'),
      peer = File('$root/test/peer.dart');
  await first.parent.create(recursive: true);
  await peer.parent.create(recursive: true);
  await first.writeAsBytes(utf8.encode('\ufeff// café\r\n'));
  await peer.writeAsString('// peer\n');
  Future<String> git(List<String> args) async {
    final result = await Process.run(
      '/usr/bin/git',
      [
        '-C',
        root,
        '-c',
        'core.hooksPath=/dev/null',
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        '-c',
        'commit.gpgsign=false',
        ...args,
      ],
      includeParentEnvironment: false,
      environment: {
        'PATH': '/usr/bin:/bin',
        'GIT_CONFIG_NOSYSTEM': '1',
        'GIT_CONFIG_GLOBAL': '/dev/null',
      },
    );
    expect(result.exitCode, 0, reason: result.stderr.toString());
    return result.stdout.toString().trim();
  }

  await git(['init', '-q']);
  await git(['add', '.']);
  await git(['commit', '-qm', 'captured fixture']);
  final capturedCommit = await git(['rev-parse', 'HEAD']);
  final reader = NativeProjectSourceHost();
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  var db = await databaseFactoryIo.openDatabase('${base.path}/records.db');
  ImportedCommitComparisonController? controller;
  final evidence = <String, Object?>{};
  try {
    final request = ProjectSourceReadRequest(
      root: root,
      python: python,
      selectedPaths: ['lib/main.dart', 'test/peer.dart'],
    );
    final observation = await reader.inspect(request);
    await reader.dispose();
    final context = ImportedSourceContext.capture(
      inspection: ProjectInspection(
        root: root,
        packageName: 'synthetic_commit_compare',
        dartSdk: '^3.0.0',
        runners: ['web'],
      ),
      requirements: RequirementsBoard(),
      request: request,
      observation: observation,
    );
    final plan = ImportedPlan(
      text: 'Synthetic historical plan',
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
    await peer.writeAsString('// changed peer\n');
    await git(['add', '.']);
    await git(['commit', '-qm', 'changed fixture']);
    final changedCommit = await git(['rev-parse', 'HEAD']);
    final index = await File('$root/.git/index').readAsBytes();
    final records = await StudioDatabase.migrate(db, prefs);
    await InspectedFolderStore(records).save(root);
    await RuntimeSetupStore(records).save(const RuntimeSetup(python: python));
    await records.setString(
      ImportedSourceProposalStore.key(root),
      saved.encode(),
    );
    final rows = StoreRef<String, String>('records');
    final before = {for (final r in await rows.find(db)) r.key: r.value};
    final c = ImportedCommitComparisonController(
      saved: saved,
      store: ImportedCommitComparisonStore(records),
    );
    controller = c;
    var confirmations = 0;
    Future<bool> confirm(ImportedCommitReadRequest value) async {
      confirmations++;
      expect(value.root, root);
      expect(value.selectedPaths, request.selectedPaths);
      return true;
    }

    c.setCommit(capturedCommit);
    await c.recheck(confirm: confirm);
    expect(c.error, isNull);
    expect(c.comparison!.matched, true);
    final matched = c.comparison!;
    c.setCommit(changedCommit);
    await c.recheck(confirm: confirm);
    expect(c.error, isNull);
    expect(c.comparison!.changedPaths, ['test/peer.dart']);
    final changed = c.comparison!;
    c.setCommit('f' * 40);
    await c.recheck(confirm: confirm);
    expect(c.refusal!.reason, 'object_unavailable');
    expect(c.comparison, same(changed));
    expect(c.stale, true);
    expect({for (final r in await rows.find(db)) r.key: r.value}, before);
    expect(await File('$root/.git/index').readAsBytes(), index);
    expect(await git(['rev-parse', 'HEAD']), changedCommit);
    expect(await first.readAsBytes(), utf8.encode('\ufeff// café\r\n'));
    expect(await peer.readAsString(), '// changed peer\n');
    expect(c.store.readOwned, false);
    expect(confirmations, 3);
    evidence.addAll({
      'claim': 'owned-temporary-commit-comparison-controller-native-db',
      'root': root,
      'capturedCommit': capturedCommit,
      'changedCommit': changedCommit,
      'savedRecordSha256': saved.digest,
      'matchedResultSha256': matched.digest,
      'changedResultSha256': changed.digest,
      'refusal': c.refusal!.reason,
      'confirmations': confirmations,
      'recordsUnchanged': true,
      'indexAndHeadUnchanged': true,
      'sourceVerified': false,
      'modelRequests': 0,
      'ownerSourceAccess': false,
    });
    if (exercisePlanning) {
      await records.setString(
        ImportedPlanStore.key(root),
        jsonEncode(plan.toJson()),
      );
      c.setCommit(changedCommit);
      await c.recheck(confirm: confirm);
      final inspection = ProjectInspection(
        root: root,
        packageName: 'synthetic_commit_compare',
        dartSdk: '^3.0.0',
        runners: ['web'],
      );
      final committed = await c.preparePlanning(inspection);
      expect(committed, isNotNull);
      expect(committed!.files.last.source.text, '// changed peer\n');
      final planner = ImportedPlanController(
        root,
        ImportedPlanStore(records, capturedCommit: committed),
        inspection: inspection,
      );
      await planner.load();
      expect(planner.approved, false);
      await planner.decide(true);
      expect(planner.error, isNotNull);
      expect(ImportedPlanStore(records).load(root)!.context, plan.context);
      await planner.saveDraft('Review exact committed source');
      expect(planner.error, isNull);
      expect(planner.approved, false);
      await planner.decide(true);
      expect(planner.approved, true);
      final planRaw = records.getString(ImportedPlanStore.key(root));
      planner.dispose();
      c.dispose();
      await db.close();
      db = await databaseFactoryIo.openDatabase('${base.path}/records.db');
      final reopened = await StudioDatabase.migrate(db, prefs);
      final restored = ImportedCommitContext.restore(
        ImportedPlanStore(reopened).load(root)!.context,
      );
      final explicit = ImportedPlanController(
        root,
        ImportedPlanStore(reopened, capturedCommit: restored),
        inspection: inspection,
      );
      final ordinary = ImportedPlanController(
        root,
        ImportedPlanStore(reopened),
        inspection: inspection,
      );
      await explicit.load();
      await ordinary.load();
      expect(explicit.approved, true);
      expect(ordinary.approved, false);
      expect(reopened.getString(ImportedPlanStore.key(root)), planRaw);
      expect(
        reopened.getString(ImportedSourceProposalStore.key(root)),
        saved.encode(),
      );
      expect(await File('$root/.git/index').readAsBytes(), index);
      expect(await git(['rev-parse', 'HEAD']), changedCommit);
      expect(await first.readAsBytes(), utf8.encode('\ufeff// café\r\n'));
      expect(await peer.readAsString(), '// changed peer\n');
      explicit.dispose();
      ordinary.dispose();
      final after = {for (final row in await rows.find(db)) row.key: row.value};
      after.remove(ImportedPlanStore.key(root));
      expect(after, before);
      evidence.addAll({
        'recordsUnchanged': false,
        'comparisonPhaseRecordsUnchanged': true,
        'onlyPlanRecordChanged': true,
        'manualDraftAndApprovalReopened': true,
        'ordinaryApprovalInactive': true,
        'savedComparisonPreserved': true,
        'commitContextSha256': restored.digest,
      });
    }
  } finally {
    controller?.dispose();
    await reader.dispose();
    await db.close();
    await base.delete(recursive: true);
  }
  evidence['temporaryRootRemoved'] = !await base.exists();
  return evidence;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'commit selection freezes shared five-key durable read-only inputs',
    () async {
      final saved = baselineSaved(),
          records = await baselineRecords(baselineSaved());
      final store = ImportedCommitComparisonStore(records),
          selection = store.prepare(saved, 'a' * 40);
      expect(selection.inputs.length, 5);
      expect(() => selection.inputs.clear(), throwsUnsupportedError);
      final before = Map<String, String>.of(records.values);
      await store.verify(selection, () {});
      expect(records.values, before);
      expect(records.updatesSeen, everyElement(isEmpty));
    },
  );
  test(
    'durable changes behind cache to each frozen input prevent confirmation',
    () async {
      final temp = await Directory.systemTemp.createTemp('asg-commit-fences-');
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final db = await databaseFactoryIo.openDatabase(
        '${temp.path}/records.db',
      );
      try {
        final saved = baselineSaved(),
            seed = await baselineRecords(baselineSaved()),
            records = await StudioDatabase.migrate(db, prefs);
        for (final e in seed.values.entries) {
          await records.setString(e.key, e.value);
        }
        final store = ImportedCommitComparisonStore(records),
            selection = store.prepare(saved, 'a' * 40),
            rows = StoreRef<String, String>('records');
        for (final e in selection.inputs.entries) {
          await rows.record(e.key).put(db, 'changed');
          expect(records.getString(e.key), e.value);
          await expectLater(store.verify(selection, () {}), throwsStateError);
          if (e.value == null) {
            await rows.record(e.key).delete(db);
          } else {
            await rows.record(e.key).put(db, e.value!);
          }
        }
      } finally {
        await db.close();
        await temp.delete(recursive: true);
      }
    },
  );
  test(
    'actual Mac commit comparison preserves all records index refs and working files',
    () async {
      final evidence = await actualCommitComparisonFixture();
      expect(evidence['temporaryRootRemoved'], true);
    },
    skip: !Platform.isMacOS
        ? 'Known Mac Python/native host; no other-host claim.'
        : false,
  );
}
