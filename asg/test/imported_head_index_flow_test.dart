// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/controllers/imported_index_controller.dart';
import 'package:asg/controllers/imported_workfile_controller.dart';
import 'package:asg/controllers/imported_head_index_controller.dart';
import 'package:asg/models/imported_head_index_observation.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/imported_index_host_native.dart';
import 'package:asg/services/imported_index_store.dart';
import 'package:asg/services/imported_workfile_host_native.dart';
import 'package:asg/services/imported_workfile_store.dart';
import 'package:asg/services/imported_head_index_host.dart';
import 'package:asg/services/imported_head_index_host_native.dart';
import 'package:asg/services/imported_head_index_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/services/studio_database.dart';

import 'imported_index_flow_test.dart' show nativeIndexFixture;

class CountingHeadIndexHost implements ImportedHeadIndexHost {
  CountingHeadIndexHost(this.native);
  final NativeImportedHeadIndexHost native;
  int calls = 0;
  @override
  bool get supported => native.supported;
  @override
  bool get cleanupConfirmed => native.cleanupConfirmed;
  @override
  ImportedHeadIndexObservation? get lastObservation => native.lastObservation;
  @override
  Future<ImportedHeadIndexObservation> inspect(ImportedHeadIndexRequest r) {
    calls++;
    return native.inspect(r);
  }

  @override
  Future<void> cancel() => native.cancel();
  @override
  Future<void> dispose() => native.dispose();
}

List<int> objectEnvelope(String kind, List<int> bytes) => [
  ...ascii.encode('$kind ${bytes.length}'),
  0,
  ...bytes,
];
List<int> oidBytes(String value) => List.generate(
  20,
  (i) => int.parse(value.substring(i * 2, i * 2 + 2), radix: 16),
);
Future<String> looseObject(Directory git, String kind, List<int> data) async {
  final envelope = objectEnvelope(kind, data);
  final id = sha1.convert(envelope).toString();
  final parent = await Directory('${git.path}/objects/${id.substring(0, 2)}')
      .create(recursive: true);
  await File('${parent.path}/${id.substring(2)}')
      .writeAsBytes(ZLibEncoder().convert(envelope));
  return id;
}

Future<(String, String)> nativeHeadFixture(
  Directory git,
  List<int> source,
) async {
  final blob = await looseObject(git, 'blob', source);
  final lib = await looseObject(git, 'tree', [
    ...ascii.encode('100644 main.dart'),
    0,
    ...oidBytes(blob),
  ]);
  final tree = await looseObject(git, 'tree', [
    ...ascii.encode('40000 lib'),
    0,
    ...oidBytes(lib),
  ]);
  final commit = await looseObject(
    git,
    'commit',
    ascii.encode('tree $tree\nauthor Fixture\ncommitter Fixture\n\nowned\n'),
  );
  final refs = await Directory('${git.path}/refs/heads')
      .create(recursive: true);
  await File('${refs.path}/main').writeAsString('$commit\n');
  await File('${git.path}/HEAD').writeAsString('ref: refs/heads/main\n');
  return (commit, tree);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual declared-object read after database reopen preserves source inputs and fresh consent', () async {
    const python =
        '/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12';
    if (!await File(python).exists()) {
      markTestSkipped('Existing Mac fixture interpreter unavailable.');
      return;
    }
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final created = await Directory.systemTemp.createTemp(
      'asg-head-index-native-',
    );
    final base = Directory(await created.resolveSymbolicLinks());
    try {
      final root = await Directory('${base.path}/source').create();
      final git = await Directory('${root.path}/.git').create();
      final source = utf8.encode('void main() {}\r\n');
      final ids = await nativeHeadFixture(git, source);
      await File('${git.path}/index').writeAsBytes(nativeIndexFixture());
      await Directory('${root.path}/lib').create();
      final target = File('${root.path}/lib/main.dart');
      await target.writeAsBytes(source);
      await Process.run('/bin/chmod', ['0600', target.path]);
      await File('${root.path}/untracked.bin').writeAsBytes([0, 255, 7]);
      final before = <String, List<int>>{};
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is File) before[e.path] = await e.readAsBytes();
      }
      final assets = {
        for (final n in [
          'imported_head_index.py',
          'imported_index.py',
          'git_head_metadata.py',
          'imported_commit_source.py',
        ])
          n: await File('tools/$n').readAsString(),
      };
      final indexAssets = {
        for (final n in ['imported_index.py', 'git_head_metadata.py'])
          n: assets[n]!,
      };
      final workfileAssets = {
        ...indexAssets,
        'imported_workfile_comparison.py': await File(
          'tools/imported_workfile_comparison.py',
        ).readAsString(),
      };
      var db = await databaseFactoryIo.openDatabase('${base.path}/app.db');
      ImportedHeadIndexRequest? oldRequest;
      String? oldDigest;
      Map<String, Object?>? evidence;
      try {
        var records = await StudioDatabase.migrate(db, preferences);
        await InspectedFolderStore(records).save(root.path);
        await RuntimeSetupStore(records)
            .save(const RuntimeSetup(python: python));
        final keys = [
          ImportedHeadIndexStore.runtimeKey,
          InspectedFolderStore.key,
        ];
        final saved = {for (final k in keys) k: records.getString(k)};
        for (var turn = 0; turn < 2; turn++) {
          final index = ImportedIndexController(
            root: root.path,
            store: ImportedIndexStore(records),
            host: NativeImportedIndexHost(loadAssets: () async => indexAssets),
            readId: () => turn == 0 ? 'a' * 32 : 'b' * 32,
          );
          final workfile = ImportedWorkfileController(
            root: root.path,
            store: ImportedWorkfileStore(records),
            host: NativeImportedWorkfileHost(
              loadAssets: () async => workfileAssets,
            ),
            index: index,
            comparisonId: () => turn == 0 ? 'c' * 32 : 'd' * 32,
          );
          final host = CountingHeadIndexHost(
            NativeImportedHeadIndexHost(loadAssets: () async => assets),
          );
          var nonce = 0;
          final c = ImportedHeadIndexController(
            root: root.path,
            store: ImportedHeadIndexStore(records),
            host: host,
            workfile: workfile,
            readId: () => ('${turn + 1}${++nonce}').padLeft(32, '0'),
          );
          expect(c.observation, null);
          expect(host.calls, 0);
          expect(await c.prepare(), null);
          final ir = await index.prepare();
          await index.inspect(ir!, confirmed: true);
          expect(index.observationCurrent, true);
          expect(await c.prepare(), null);
          final wr = await workfile.prepare(['lib/main.dart']);
          await workfile.inspect(wr!, confirmed: true);
          expect(workfile.error, null);
          expect(workfile.observationCurrent, true);
          final cancelled = await c.prepare();
          await c.inspect(cancelled!, confirmed: false);
          expect(host.calls, 0);
          final request = await c.prepare();
          if (oldRequest != null) {
            await c.inspect(oldRequest, confirmed: true);
            expect(host.calls, 0);
          }
          await c.inspect(request!, confirmed: true);
          expect(c.error, null);
          expect(c.observationCurrent, true);
          expect(c.observation!.observed, true);
          expect(c.observation!.headOid, ids.$1);
          expect(c.observation!.treeOid, ids.$2);
          expect(c.observation!.declaredRef, 'refs/heads/main');
          expect(c.observation!.files.single.indexMatchesTree, false);
          expect(c.observation!.files.single.workingBytesMatchTree, true);
          expect(
            c.observation!.files.single.workingExecutableMatchesTree,
            true,
          );
          expect(
            c.observation!.authorizesCommit ||
                c.observation!.gitStateVerified ||
                c.observation!.repositoryAuthenticated,
            false,
          );
          expect(host.calls, 1);
          expect(host.cleanupConfirmed, true);
          expect({for (final k in keys) k: records.getString(k)}, saved);
          for (final e in before.entries) {
            expect(await File(e.key).readAsBytes(), e.value);
          }
          if (turn == 0) {
            oldRequest = request;
            oldDigest = request.digest;
            final previous = c.lastObserved;
            final lock = File('${git.path}/HEAD.lock');
            await lock.writeAsString('owned lock');
            final retry = await c.prepare();
            await c.inspect(retry!, confirmed: true);
            expect(c.observation!.observed, false);
            expect(c.observation!.files, isEmpty);
            expect(c.lastObserved, same(previous));
            expect(host.cleanupConfirmed, true);
            expect(await lock.readAsString(), 'owned lock');
            await lock.delete();
          } else {
            expect(request.digest, isNot(oldDigest));
            evidence = {
              'requestSha256': request.digest,
              'result': jsonDecode(c.observation!.recordJson),
              'sourceAndObjectsPreserved': true,
              'durableInputsPreserved': true,
              'nativeCleanupConfirmed': host.cleanupConfirmed,
              'databaseReopenedWithoutReplay': true,
              'helperSha256': sha256
                  .convert(
                    await File('tools/imported_head_index.py').readAsBytes(),
                  )
                  .toString(),
              'hostSha256': sha256
                  .convert(
                    await File(
                      'lib/services/imported_head_index_host_native.dart',
                    ).readAsBytes(),
                  )
                  .toString(),
              'modelSha256': sha256
                  .convert(
                    await File(
                      'lib/models/imported_head_index_observation.dart',
                    ).readAsBytes(),
                  )
                  .toString(),
              'modelRequests': 0,
            };
          }
          c.dispose();
          workfile.dispose();
          index.dispose();
          await Future<void>.delayed(Duration.zero);
          if (turn == 0) {
            await db.close();
            db = await databaseFactoryIo.openDatabase('${base.path}/app.db');
            records = await StudioDatabase.migrate(db, preferences);
            expect({for (final k in keys) k: records.getString(k)}, saved);
          }
        }
      } finally {
        await db.close();
      }
      await File('/tmp/asg404-declared-head-index-native-reopen-receipt.json')
          .writeAsString(jsonEncode(evidence));
    } finally {
      await base.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
