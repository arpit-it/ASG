import 'dart:async';
import 'dart:io';

import 'package:asg/controllers/project_inspection_controller.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'project_inspection_controller_test.dart' show Picker, result;

class Records implements RecordStorage {
  String? value;
  bool fail = false;
  Completer<bool>? pending;
  @override
  String? getString(String key) => value;
  @override
  Future<bool> setString(String key, String value) async {
    if (fail || (pending != null && !await pending!.future)) return false;
    this.value = value;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native database reopen retains references and freshly inspects',
    () async {
      SharedPreferences.setMockInitialValues({});
      final temp = await Directory.systemTemp.createTemp('asg-folders-');
      addTearDown(() => temp.delete(recursive: true));
      final path = '${temp.path}/records.db';
      final legacy = await SharedPreferences.getInstance();
      var db = await StudioDatabase.migrate(
        await databaseFactoryIo.openDatabase(path),
        legacy,
      );
      final c = ProjectInspectionController(
        store: InspectedFolderStore(db),
        picker: Picker(),
        inspect: (root) async => result(root),
      );
      await c.chooseFolder();
      expect(c.savedFolders, isEmpty);
      await c.saveFolder();
      await c.saveFolder();
      expect(c.savedFolders, ['/project']);
      c.dispose();
      await db.database.close();
      db = await StudioDatabase.migrate(
        await databaseFactoryIo.openDatabase(path),
        legacy,
      );
      var reads = 0;
      var missing = false;
      final reopened = ProjectInspectionController(
        store: InspectedFolderStore(db),
        picker: Picker(),
        inspect: (root) async {
          reads++;
          if (missing) throw const FormatException('Folder is missing');
          return result(root);
        },
      );
      expect(reopened.findings, isNull);
      expect(reopened.savedFolders, ['/project']);
      await reopened.reopen('/project');
      expect(reads, 1);
      expect(reopened.findings?.root, '/project');
      missing = true;
      await reopened.reopen('/project');
      expect(reopened.findings, isNull);
      expect(reopened.error, contains('missing'));
      expect(reopened.savedFolders, ['/project']);
      reopened.dispose();
      await db.database.close();
    },
  );
  test(
    'failed save retries and pending save excludes other operations',
    () async {
      final records = Records()..fail = true;
      final picker = Picker();
      final c = ProjectInspectionController(
        store: InspectedFolderStore(records),
        picker: picker,
        inspect: (root) async => result(root),
      );
      await c.chooseFolder();
      await c.saveFolder();
      expect(c.savedFolders, isEmpty);
      expect(c.error, contains('could not be saved'));
      records.fail = false;
      records.pending = Completer<bool>();
      final save = c.saveFolder();
      await c.chooseFolder();
      await c.saveFolder();
      expect(picker.calls, 1);
      expect(c.savedFolders, isEmpty);
      records.pending!.complete(true);
      await save;
      expect(c.savedFolders, ['/project']);
      expect(c.error, isNull);
      c.dispose();
    },
  );
  test('corruption remains untouched and cannot be overwritten', () async {
    for (final raw in ['{}', '[1]', '["/a","/a"]', '[""]', 'invalid']) {
      final records = Records()..value = raw;
      final store = InspectedFolderStore(records);
      final c = ProjectInspectionController(
        store: store,
        picker: Picker(),
        inspect: (root) async => result(root),
      );
      expect(c.storageError, isNotNull);
      await c.chooseFolder();
      await c.saveFolder();
      expect(records.value, raw);
      await expectLater(store.save('/project'), throwsFormatException);
      c.dispose();
    }
  });
  test('disposal during save ignores late state publication', () async {
    final records = Records()..pending = Completer<bool>();
    final c = ProjectInspectionController(
      store: InspectedFolderStore(records),
      picker: Picker(),
      inspect: (root) async => result(root),
    );
    await c.chooseFolder();
    final save = c.saveFolder();
    c.dispose();
    records.pending!.complete(true);
    await save;
    expect(c.savedFolders, isEmpty);
    expect(InspectedFolderStore(records).load(), ['/project']);
  });
}
