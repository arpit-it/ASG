// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('vm')
library;

import 'dart:io';
import 'dart:convert';

import 'package:asg/controllers/model_settings_controller.dart';

import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_connection_preset.dart';
import 'package:asg/models/model_profile_notes.dart';
import 'package:asg/models/model_test_observation.dart';
import 'package:asg/models/model_runtime_metrics.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealHttpOverrides extends HttpOverrides {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'actual HTTP tests attach exact requested connection with fixed test ceiling',
    () => HttpOverrides.runWithHttpOverrides(() async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final requests = <Map<String, dynamic>>[];
      server.listen((request) async {
        expect(request.uri.path, '/v1/chat/completions');
        final body = jsonDecode(
          await utf8.decoder.bind(request).join(),
        ) as Map<String, dynamic>;
        requests.add(body);
        request.response.headers.contentType = ContentType.json;
        request.response.write(
          jsonEncode({
            'model': body['model'],
            'choices': [
              {
                'message': {
                  'content': requests.length == 1
                      ? 'private response'
                      : '{"asg_probe":"ok"}',
                },
              },
            ],
          }),
        );
        await request.response.close();
      });
      SharedPreferences.setMockInitialValues({});
      final store = ModelSettingsStore.fromPreferences(
        await SharedPreferences.getInstance(),
      );
      final config = LocalModelConfig(
        baseUrl: 'http://127.0.0.1:${server.port}/v1',
        model: 'exact-request',
        chatOutputTokens: 2048,
      );
      final controller = ModelSettingsController(store);
      try {
        await controller.savePreset(
          'HTTP',
          config,
          profileNotes: const ModelProfileNotes(revision: 'http-test-time'),
        );
        controller.selectPreset('HTTP');
        for (final json in [false, true]) {
          await controller.test(config, jsonFormat: json);
          expect(controller.canSaveTestObservation(config), isTrue);
          await controller.saveTestObservation(config);
          final saved = store.loadPresets().single;
          expect(saved.testObservation!.jsonFormat, json);
          expect(
            saved.testObservation!.profileNotes!.revision,
            'http-test-time',
          );
          expect(saved.testObservation!.responseModel, 'exact-request');
          expect(saved.config.baseUrl, config.baseUrl);
          expect(saved.config.model, 'exact-request');
          expect(saved.config.chatOutputTokens, 2048);
        }
        await controller.saveProfileNotes(
          config,
          const ModelProfileNotes(revision: 'edited-without-inference'),
        );
        expect(store.loadPresets().single.testObservation!.jsonFormat, isTrue);
        expect(
          store.loadPresets().single.profileNotes!.revision,
          'edited-without-inference',
        );
        expect(
          store.loadPresets().single.testObservation!.profileNotes!.revision,
          'http-test-time',
        );
        expect(requests.length, 2);
        await controller.removeTestObservation();
        expect(store.loadPresets().single.testObservation, isNull);
        expect(store.loadPresets().single.config.model, 'exact-request');
        expect(requests.length, 2);
        for (final request in requests) {
          expect(request['max_tokens'], 256);
          expect(request['model'], 'exact-request');
        }
        expect(store.load().model, const LocalModelConfig().model);
      } finally {
        controller.dispose();
        await server.close(force: true);
      }
    }, _RealHttpOverrides()),
  );
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
          ModelConnectionPreset(
            name: 'Local',
            testObservation: ModelTestObservation(
              jsonFormat: true,
              observedAt: DateTime.utc(2026, 11, 2),
              firstTextMilliseconds: 12,
              completedMilliseconds: 34,
              responseModel: 'saved',
              profileNotes: const ModelProfileNotes(
                revision: 'test-time',
                contextTokens: 4096,
              ),
              runtimeMetrics: const ModelRuntimeMetrics(
                promptTokens: 42,
                completionTokens: 2,
                tokensPerSecond: 12.5,
                peakMemoryGb: 6.25,
              ),
            ),
            config: LocalModelConfig(model: 'saved'),
            profileNotes: ModelProfileNotes(
              revision: 'exact-revision',
              contextTokens: 8192,
            ),
          ),
        ]);
        await db.close();
        db = await databaseFactoryIo.openDatabase(path);
        records = await StudioDatabase.migrate(db, prefs);
        expect(
          ModelSettingsStore(records)
              .loadPresets()
              .single
              .testObservation!
              .profileNotes!
              .revision,
          'test-time',
        );
        expect(
          ModelSettingsStore(records).loadPresets().single.config.model,
          'saved',
        );
        expect(
          ModelSettingsStore(records)
              .loadPresets()
              .single
              .profileNotes!
              .contextTokens,
          8192,
        );
        expect(
          ModelSettingsStore(records)
              .loadPresets()
              .single
              .profileNotes!
              .revision,
          'exact-revision',
        );
        final savedObservation = ModelSettingsStore(records)
            .loadPresets()
            .single
            .testObservation!;
        expect(savedObservation.jsonFormat, isTrue);
        expect(savedObservation.responseModel, 'saved');
        expect(savedObservation.observedAt, DateTime.utc(2026, 11, 2));
        expect(savedObservation.runtimeMetrics!.promptTokens, 42);
        expect(savedObservation.runtimeMetrics!.tokensPerSecond, 12.5);
        expect(savedObservation.runtimeMetrics!.peakMemoryGb, 6.25);
        expect(savedObservation.completedMilliseconds, 34);
        final editor = ModelSettingsController(ModelSettingsStore(records));
        final selectedConfig = editor.selectPreset('Local')!;
        await editor.saveProfileNotes(
          selectedConfig,
          const ModelProfileNotes(
            revision: 'edited-revision',
            contextTokens: 4096,
          ),
        );
        editor.dispose();
        await db.close();
        db = await databaseFactoryIo.openDatabase(path);
        records = await StudioDatabase.migrate(db, prefs);
        final afterEdit = ModelSettingsStore(records).loadPresets().single;
        expect(afterEdit.profileNotes!.revision, 'edited-revision');
        expect(afterEdit.profileNotes!.contextTokens, 4096);
        expect(afterEdit.testObservation!.toJson(), savedObservation.toJson());
        expect(afterEdit.config.model, 'saved');
        final removal = ModelSettingsController(ModelSettingsStore(records));
        removal.selectPreset('Local');
        await removal.removeTestObservation();
        removal.dispose();
        await db.close();
        db = await databaseFactoryIo.openDatabase(path);
        records = await StudioDatabase.migrate(db, prefs);
        final afterRemoval = ModelSettingsStore(records).loadPresets().single;
        expect(afterRemoval.testObservation, isNull);
        expect(afterRemoval.config.model, 'saved');
        expect(afterRemoval.profileNotes!.revision, 'edited-revision');
        // Real conditional storage refuses a stale profile-only replacement.
        final store = ModelSettingsStore(records);
        final before = store.loadPresets();
        await store.savePresets([
          const ModelConnectionPreset(
            name: 'Local',
            config: LocalModelConfig(model: 'saved'),
            profileNotes: ModelProfileNotes(revision: 'new-revision'),
          ),
        ], expected: before);
        await expectLater(
          store.savePresets([], expected: before),
          throwsStateError,
        );
        expect(
          store.loadPresets().single.profileNotes!.revision,
          'new-revision',
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
