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

Future<void> packNativeFixture(Directory git, String python) async {
  // Trusted owned-fixture preparation only; the application never invokes this.
  const prepare = r'''import sys, zlib
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from test_imported_head_index import pack_fixture
folder = Path(sys.argv[2]); objects = []; paths = []
for path in sorted((folder / 'objects').glob('*/*')):
    if not path.is_file(): continue
    raw = zlib.decompress(path.read_bytes()); prefix, body = raw.split(b'\0', 1)
    objects.append((prefix.split(b' ', 1)[0].decode('ascii'), body)); paths.append(path)
pack, index, _ = pack_fixture(objects, delta_kinds=('commit', 'tree', 'blob'), depth=2)
target = folder / 'objects' / 'pack'; target.mkdir()
name = 'pack-' + pack[-20:].hex()
(target / (name + '.pack')).write_bytes(pack)
(target / (name + '.idx')).write_bytes(index)
(target / 'multi-pack-index').write_bytes(b'opaque owned fixture')
for path in paths: path.unlink()
''';
  final result = await Process.run(
    python,
    [
      '-I',
      '-S',
      '-B',
      '-c',
      prepare,
      await Directory('tools').resolveSymbolicLinks(),
      git.path,
    ],
    runInShell: false,
    includeParentEnvironment: false,
  );
  expect(result.exitCode, 0, reason: '${result.stderr}');
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
      final commitFile = File(
        '${git.path}/objects/${ids.$1.substring(0, 2)}/${ids.$1.substring(2)}',
      );
      final commitBytes = await commitFile.readAsBytes();
      await packNativeFixture(git, python);
      final packed = File('${git.path}/packed-refs');
      final loose = File('${git.path}/refs/heads/main');
      await packed.writeAsString(
        '# pack-refs with: peeled fully-peeled sorted \n${ids.$1} refs/heads/main\n',
      );
      await loose.delete();
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
          'imported_pack_objects.py',
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
          if (turn == 1) {
            // Owned fixture transition: loose commit and ref precedence after reopen.
            await commitFile.writeAsBytes(commitBytes);
            before[commitFile.path] = await commitFile.readAsBytes();
            await loose.writeAsString('${ids.$1}\n');
            await packed.writeAsString(
              '# pack-refs with: peeled fully-peeled sorted \n${'b' * 40} refs/heads/main\n',
            );
            before[loose.path] = await loose.readAsBytes();
            before[packed.path] = await packed.readAsBytes();
          }
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
          final acquisition = c.observation!.objectAcquisition!;
          expect(acquisition.packedObjectCount, greaterThan(0));
          expect(acquisition.looseObjectCount, turn == 0 ? 0 : 1);
          expect(acquisition.maxDeltaDepth, 2);
          expect(acquisition.wholePackIntegrityVerified, false);
          expect(acquisition.indexes.length, 1);
          final packIndex =
              (await Directory('${git.path}/objects/pack').list().toList())
                  .whereType<File>()
                  .singleWhere((file) => file.path.endsWith('.idx'));
          expect(
            acquisition.indexes.single.indexHash,
            sha256.convert(await packIndex.readAsBytes()).toString(),
          );
          final reference = c.observation!.referenceAcquisition!;
          expect(reference.source.name, turn == 0 ? 'packedRef' : 'looseRef');
          expect(
            reference.packedRefsHash,
            sha256.convert(await packed.readAsBytes()).toString(),
          );
          expect(reference.packedRefsByteLength, await packed.length());
          expect(reference.packedRefsEntryCount, 1);
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
            final lock = File('${git.path}/packed-refs.lock');
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
              'packHelperSha256': sha256
                  .convert(
                    await File('tools/imported_pack_objects.py').readAsBytes(),
                  )
                  .toString(),
              'objectAcquisitionModelSha256': sha256
                  .convert(
                    await File('lib/models/imported_object_acquisition.dart')
                        .readAsBytes(),
                  )
                  .toString(),
              'modelRequests': 0,
              'fixtureObjectTransition': 'packed depth2 objects then loose commit with packed trees and blobs after reopen',
              'fixtureReferenceTransition': 'packed fallback then loose precedence with differing packed label after reopen',
              'referenceModelSha256': sha256
                  .convert(
                    await File('lib/models/imported_reference_acquisition.dart')
                        .readAsBytes(),
                  )
                  .toString(),
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
      await File('/tmp/asg404-packed-object-native-reopen-receipt.json')
          .writeAsString(jsonEncode(evidence));
    } finally {
      await base.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
