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
        final raw = StoreRef<String, String>('records');
        const appKey = 'studio.application.v1.damaged';
        const generationKey = 'studio.generation.v1.damaged';
        await raw.record(appKey).put(db, 'broken app');
        await raw.record(generationKey).put(db, 'broken generation');
        await db.close();
        db = await databaseFactoryWeb.openDatabase(
          name,
          mode: DatabaseMode.create,
        );
        final isolated = await StudioDatabase.migrate(db, prefs);
        expect(isolated.getString('studio.lastProject.v1'), 'updated');
        expect(() => isolated.getString(appKey), throwsFormatException);
        expect(() => isolated.getString(generationKey), throwsFormatException);
        expect(await raw.record(appKey).get(db), 'broken app');
        expect(await raw.record(generationKey).get(db), 'broken generation');
        await expectLater(
          isolated.setString(appKey, 'invalid'),
          throwsFormatException,
        );
      } finally {
        await db.close();
        await databaseFactoryWeb.deleteDatabase(name);
      }
    },
  );
}
