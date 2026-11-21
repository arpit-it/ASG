// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/controllers/imported_index_controller.dart';
import 'package:asg/models/imported_index_observation.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/imported_index_host.dart';
import 'package:asg/services/imported_index_host_native.dart';
import 'package:asg/services/imported_index_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/services/studio_database.dart';

class CountingIndexHost implements ImportedIndexHost {
  CountingIndexHost(this.native);
  final NativeImportedIndexHost native;
  int calls = 0;
  @override
  bool get supported => native.supported;
  @override
  bool get cleanupConfirmed => native.cleanupConfirmed;
  @override
  ImportedIndexObservation? get lastObservation => native.lastObservation;
  @override
  Future<ImportedIndexObservation> inspect(ImportedIndexReadRequest request) {
    calls++;
    return native.inspect(request);
  }

  @override
  Future<void> cancel() => native.cancel();
  @override
  Future<void> dispose() => native.dispose();
}

Uint8List nativeIndexFixture() {
  final path = utf8.encode('lib/main.dart');
  final stat = ByteData(40)..setUint32(24, 0x81a4, Endian.big);
  final flags = ByteData(2)..setUint16(0, path.length, Endian.big);
  final item = <int>[
    ...stat.buffer.asUint8List(),
    ...List.filled(20, 0x61),
    ...flags.buffer.asUint8List(),
    ...path,
    0,
  ];
  item.addAll(List.filled((-item.length) % 8, 0));
  final header = ByteData(12)
    ..setUint32(0, 0x44495243, Endian.big)
    ..setUint32(4, 2, Endian.big)
    ..setUint32(8, 1, Endian.big);
  final cacheSize = ByteData(4)..setUint32(0, 3, Endian.big);
  final raw = <int>[
    ...header.buffer.asUint8List(),
    ...item,
    ...ascii.encode('TREE'),
    ...cacheSize.buffer.asUint8List(),
    0,
    255,
    7,
  ];
  return Uint8List.fromList([...raw, ...sha1.convert(raw).bytes]);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual index reader after database reopen preserves source metadata and both durable inputs', () async {
    const python =
        '/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12';
    if (!await File(python).exists()) {
      markTestSkipped('Existing Mac fixture interpreter unavailable.');
      return;
    }
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final created = await Directory.systemTemp.createTemp('asg-index-native-');
    final base = Directory(await created.resolveSymbolicLinks());
    try {
      final root = await Directory('${base.path}/source').create();
      final git = await Directory('${root.path}/.git').create();
      final raw = nativeIndexFixture();
      await File('${git.path}/index').writeAsBytes(raw);
      await File('${git.path}/packed-refs')
          .writeAsString('owned unrelated packed refs');
      await File('${git.path}/HEAD').writeAsString('ref: refs/heads/main\n');
      await File('${root.path}/dirty.dart')
          .writeAsString('keep working bytes\n');
      await File('${root.path}/untracked.bin').writeAsBytes([0, 255, 7]);
      final before = <String, List<int>>{};
      await for (final e in root.list(recursive: true, followLinks: false)) {
        if (e is File) before[e.path] = await e.readAsBytes();
      }
      final assets = {
        for (final name in ['imported_index.py', 'git_head_metadata.py'])
          name: await File('tools/$name').readAsString(),
      };
      CountingIndexHost host() => CountingIndexHost(
        NativeImportedIndexHost(loadAssets: () async => assets),
      );
      var database = await databaseFactoryIo.openDatabase(
        '${base.path}/app.db',
      );
      Map<String, dynamic>? evidence;
      try {
        final records = await StudioDatabase.migrate(database, preferences);
        await InspectedFolderStore(records).save(root.path);
        await RuntimeSetupStore(records)
            .save(const RuntimeSetup(python: python));
        final keys = [ImportedIndexStore.runtimeKey, InspectedFolderStore.key];
        final saved = {for (final k in keys) k: records.getString(k)};
        final firstHost = host();
        var nonce = 0;
        final c = ImportedIndexController(
          root: root.path,
          store: ImportedIndexStore(records),
          host: firstHost,
          readId: () => (++nonce).toRadixString(16).padLeft(32, '0'),
        );
        final cancelled = await c.prepare();
        expect(firstHost.calls, 0);
        await c.inspect(cancelled!, confirmed: false);
        expect(firstHost.calls, 0);
        final request = await c.prepare();
        await c.inspect(request!, confirmed: true);
        expect(c.error, isNull);
        expect(c.observationCurrent, true);
        expect(c.observation!.status, ImportedIndexStatus.observed);
        expect(c.observation!.optionalCaches, ['TREE']);
        expect(c.observation!.entries.single.path, 'lib/main.dart');
        expect(c.observation!.gitStateVerified, false);
        expect(c.observation!.headMembership, 'unknown');
        expect(firstHost.cleanupConfirmed, true);
        expect({for (final k in keys) k: records.getString(k)}, saved);
        final firstDigest = request.digest;
        final firstIndexHash = c.observation!.indexHash;
        c.dispose();
        await Future<void>.delayed(Duration.zero);
        await database.close();
        database = await databaseFactoryIo.openDatabase('${base.path}/app.db');
        final reopened = await StudioDatabase.migrate(database, preferences);
        expect({for (final k in keys) k: reopened.getString(k)}, saved);
        final secondHost = host();
        final next = ImportedIndexController(
          root: root.path,
          store: ImportedIndexStore(reopened),
          host: secondHost,
          readId: () => 'b' * 32,
        );
        expect(next.observation, isNull);
        expect(secondHost.calls, 0);
        final fresh = await next.prepare();
        await next.inspect(request, confirmed: true);
        expect(secondHost.calls, 0);
        await next.inspect(fresh!, confirmed: true);
        expect(next.error, isNull);
        expect(next.observationCurrent, true);
        expect(next.observation!.indexHash, firstIndexHash);
        expect(fresh.digest, isNot(firstDigest));
        expect(secondHost.calls, 1);
        expect(secondHost.cleanupConfirmed, true);
        expect({for (final k in keys) k: reopened.getString(k)}, saved);
        for (final e in before.entries) {
          expect(await File(e.key).readAsBytes(), e.value);
        }
        evidence = {
          'requestSha256': fresh.digest,
          'result': jsonDecode(next.observation!.recordJson),
          'sourceBytesPreserved': true,
          'durableInputsPreserved': true,
          'nativeCleanupConfirmed': secondHost.cleanupConfirmed,
          'databaseReopenedWithoutReplay': true,
          'helperSha256': sha256
              .convert(await File('tools/imported_index.py').readAsBytes())
              .toString(),
          'hostSha256': sha256
              .convert(
                await File('lib/services/imported_index_host_native.dart')
                    .readAsBytes(),
              )
              .toString(),
          'modelSha256': sha256
              .convert(
                await File('lib/models/imported_index_observation.dart')
                    .readAsBytes(),
              )
              .toString(),
          'modelRequests': 0,
        };
        next.dispose();
        await Future<void>.delayed(Duration.zero);
      } finally {
        await database.close();
      }
      await File('/tmp/asg404-index-native-reopen-receipt.json')
          .writeAsString(jsonEncode(evidence));
    } finally {
      await base.delete(recursive: true);
    }
  }, skip: !Platform.isMacOS);
}
