// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:crypto/crypto.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/controllers/imported_commit_copy_recheck_controller.dart';
import 'package:asg/models/imported_commit_copy_request.dart';
import 'package:asg/models/imported_commit_copy_observation.dart';
import 'package:asg/models/imported_commit_copy_record.dart';
import 'package:asg/models/imported_commit_copy_recheck.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/imported_commit_copy_recheck_host_native.dart';
import 'package:asg/services/imported_commit_copy_recheck_store.dart';
import 'package:asg/services/imported_commit_copy_store.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/studio_database.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('actual owned native read and durable zero-update admission preserve source and copy journal across reopen', () async {
    const python =
        '/Library/Frameworks/Python.framework/Versions/3.12/bin/python3.12';
    if (!Platform.isMacOS || !await File(python).exists()) {
      markTestSkipped('Existing Mac interpreter unavailable.');
      return;
    }
    final created = await Directory.systemTemp.createTemp(
          'asg-recheck-native-',
        ),
        base = Directory(await created.resolveSymbolicLinks());
    StudioDatabase? db;
    NativeImportedCommitCopyRecheckHost? host;
    try {
      final fixture = await Process.run(
        python,
        [
          '-I',
          '-S',
          '-B',
          '-c',
          r'''
import sys,json
from pathlib import Path
sys.path.insert(0,sys.argv[1])
from test_imported_commit_copy import CopyTests
f=CopyTests();f.parent=Path(sys.argv[2]);f.source=f.parent/'source';f.source.mkdir();f.git('init','-q')
data=f.fixture();value=f.run_copy(data)
assert value['status']=='prepared',value
print(json.dumps({'request':json.dumps(data,separators=(',',':')),'result':json.dumps(value,separators=(',',':'))}))
''',
          Directory('tools').absolute.path,
          base.path,
        ],
        environment: const {},
        includeParentEnvironment: false,
      );
      expect(
        fixture.exitCode,
        0,
        reason: 'Disposable trusted copy fixture failed.',
      );
      final payload = jsonDecode(fixture.stdout as String) as Map;
      final original = ImportedCommitCopyRequest.restore(
        payload['request'] as String,
      );
      final receipt = ImportedCommitCopyObservation.fromJson(
        payload['result'] as String,
        request: original,
      );
      final at = DateTime.now().toUtc();
      final history = ImportedCommitCopyRecord.empty(original.root)
          .begin(original, at)
          .settle(original, receipt, at);
      final root = Directory(original.root),
          copy = Directory(receipt.copyPath!);
      await File('${root.path}/lib/main.dart').writeAsString('owner dirty');
      await File('${root.path}/untracked').writeAsString('keep');
      Future<Map<String, String>> fileHashes() async {
        final result = <String, String>{};
        await for (final entity in root.list(
          recursive: true,
          followLinks: false,
        )) {
          if (entity is File) {
            result[entity.path.substring(root.path.length)] = sha256
                .convert(await entity.readAsBytes())
                .toString();
          }
        }
        return result;
      }

      final before = await fileHashes();
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final databasePath = '${base.path}/studio.db';
      db = await StudioDatabase.migrate(
        await databaseFactoryIo.openDatabase(databasePath),
        prefs,
      );
      await InspectedFolderStore(db).save(root.path);
      await RuntimeSetupStore(db).save(const RuntimeSetup(python: python));
      await db.setString(
        ImportedCommitCopyStore.key(root.path),
        history.recordJson,
      );
      final tools = {
        for (final name in [
          'imported_commit_copy_recheck.py',
          'prepare_self_candidate.py',
        ])
          name: await File('tools/$name').readAsString(),
      };
      host = NativeImportedCommitCopyRecheckHost(loadAssets: () async => tools);
      final c = ImportedCommitCopyRecheckController(
        root: root.path,
        expectedHistoryDigest: history.digest,
        store: ImportedCommitCopyRecheckStore(db),
        host: host,
        recheckId: () => 'b' * 32,
      );
      await c.load();
      expect(c.result, isNull);
      expect(c.canRecheck, true);
      // The original repository need not remain present for a copy-only observation.
      final moved = Directory('${base.path}/temporarily-moved-source');
      await root.rename(moved.path);
      try {
        await c.recheck(c.request!);
      } finally {
        await moved.rename(root.path);
      }
      expect(c.result?.status, ImportedCommitCopyRecheckStatus.matching);
      expect(host.cleanupConfirmed, true);
      expect(c.result?.observedFingerprint, receipt.fingerprint);
      expect(await fileHashes(), before);
      expect(
        db.getString(ImportedCommitCopyStore.key(root.path)),
        history.recordJson,
      );
      final peer = File('${copy.path}/peer.bin'),
          peerBytes = await File('${copy.path}/peer.bin').readAsBytes();
      await peer.writeAsBytes([1, 2, 3]);
      await c.load();
      await c.recheck(c.request!);
      expect(c.result?.status, ImportedCommitCopyRecheckStatus.changed);
      await peer.writeAsBytes(peerBytes);
      final marker = File('${copy.parent.path}/.asg-imported-copy-pending');
      await marker.writeAsString('pending');
      await c.load();
      await c.recheck(c.request!);
      expect(c.result?.status, ImportedCommitCopyRecheckStatus.refused);
      await marker.delete();
      expect(await fileHashes(), before);
      expect(
        db.getString(ImportedCommitCopyStore.key(root.path)),
        history.recordJson,
      );
      c.dispose();
      await Future<void>.delayed(Duration.zero);
      await db.database.close();
      db = null;
      db = await StudioDatabase.migrate(
        await databaseFactoryIo.openDatabase(databasePath),
        prefs,
      );
      expect(
        db.getString(ImportedCommitCopyStore.key(root.path)),
        history.recordJson,
      );
      expect(
        ImportedCommitCopyStore(db)
            .history(root.path)
            .record
            .lastPrepared!
            .observation!
            .fingerprint,
        receipt.fingerprint,
      );
      final evidence = {
        'observedAt': DateTime.now().toUtc().toIso8601String(),
        'nativeCleanupConfirmed': host.cleanupConfirmed,
        'controllerNativeDatabaseReopened': true,
        'matchingFingerprint': receipt.fingerprint,
        'changedNonselectedObserved': true,
        'pendingMarkerRefused': true,
        'originalRepositoryNotRead': true,
        'dirtySourceIndexRefsBytesPreserved': true,
        'copyHistoryUnchanged': true,
        'modelRequests': 0,
        'helperSha256': sha256
            .convert(utf8.encode(tools['imported_commit_copy_recheck.py']!))
            .toString(),
        'requestModelSha256': sha256
            .convert(
              await File('lib/models/imported_commit_copy_recheck.dart')
                  .readAsBytes(),
            )
            .toString(),
      };
      await File('/tmp/asg404-recheck-native-flow.json')
          .writeAsString(jsonEncode(evidence));
    } finally {
      await host?.dispose();
      await db?.database.close();
      if (await base.exists()) await base.delete(recursive: true);
    }
  });
}
