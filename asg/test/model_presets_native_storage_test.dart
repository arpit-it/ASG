// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('vm')
library;

import 'dart:io';

import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_connection_preset.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native database reopens presets and isolates corruption verbatim',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final dir = await Directory.systemTemp.createTemp('asg-presets-');
      final path = '${dir.path}/records.db';
      var db = await databaseFactoryIo.openDatabase(path);
      try {
        var records = await StudioDatabase.migrate(db, prefs);
        await ModelSettingsStore(records).savePresets([
          const ModelConnectionPreset(
            name: 'Local',
            config: LocalModelConfig(model: 'saved'),
          ),
        ]);
        await db.close();
        db = await databaseFactoryIo.openDatabase(path);
        records = await StudioDatabase.migrate(db, prefs);
        expect(
          ModelSettingsStore(records).loadPresets().single.config.model,
          'saved',
        );
        // Simulate disk corruption after a successful migration.
        await StoreRef<String, String>('records')
            .record(ModelSettingsStore.presetsKey)
            .put(db, '{broken');
        await db.close();
        db = await databaseFactoryIo.openDatabase(path);
        records = await StudioDatabase.migrate(db, prefs);
        expect(
          () => ModelSettingsStore(records).loadPresets(),
          throwsFormatException,
        );
        await expectLater(
          ModelSettingsStore(records).savePresets([]),
          throwsFormatException,
        );
        await ModelSettingsStore(records)
            .save(const LocalModelConfig(model: 'unrelated'));
        expect(ModelSettingsStore(records).load().model, 'unrelated');
        expect(
          await StoreRef<String, String>('records')
              .record(ModelSettingsStore.presetsKey)
              .get(db),
          '{broken',
        );
      } finally {
        await db.close();
        await dir.delete(recursive: true);
      }
    },
  );
}
