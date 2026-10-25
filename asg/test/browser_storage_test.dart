@TestOn('browser')
library;

import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast_web/sembast_web.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'IndexedDB migration, failed transaction and reopen retain data',
    () async {
      final name = 'asg-test-${DateTime.now().microsecondsSinceEpoch}';
      SharedPreferences.setMockInitialValues({
        'studio.lastProject.v1': 'legacy',
      });
      final prefs = await SharedPreferences.getInstance();
      var db = await databaseFactoryWeb.openDatabase(
        name,
        mode: DatabaseMode.create,
      );
      try {
        await expectLater(
          StudioDatabase.migrate(
            db,
            prefs,
            beforeCommit: () async => throw StateError('interrupted'),
          ),
          throwsStateError,
        );
        final records = await StudioDatabase.migrate(db, prefs);
        expect(records.getString('studio.lastProject.v1'), 'legacy');
        await records.setString('studio.lastProject.v1', 'updated');
        await db.close();
        db = await databaseFactoryWeb.openDatabase(
          name,
          mode: DatabaseMode.create,
        );
        final restored = await StudioDatabase.migrate(db, prefs);
        expect(restored.getString('studio.lastProject.v1'), 'updated');
        expect(prefs.getString('studio.lastProject.v1'), 'legacy');
      } finally {
        await db.close();
        await databaseFactoryWeb.deleteDatabase(name);
      }
    },
  );
}
