// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/repair_attempt_store.dart';
import 'package:asg/services/source_edit_proposer.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'approved_source_proposer_test.dart' show seed, originals, response;
import 'planning_conversation_test.dart' show ControlledRecords, project;
import 'source_edit_proposer_test.dart' show FakeProvider;
import 'source_candidate_controller_test.dart' show AtomicRecords;
import 'candidate_repair_proposer_test.dart' show boundFailure, saveFailure;

const request = ModelRequestProvenance(
  model: 'source-model',
  outputTokens: 4096,
);
GeneratedProject candidate({bool legacy = false, bool ready = false}) =>
    GeneratedProject(
      directory: '/separate/candidate',
      sdk: '/sdk',
      python: 'python3',
      sources: {'lib/main.dart': 'a' * 64},
      confined: true,
      sourceRequest: legacy ? null : request,
      phase: ready
          ? SourceGenerationPhase.ready
          : SourceGenerationPhase.generated,
      outputs: ready ? {'index.html': 'b' * 64, 'main.dart.js': 'c' * 64} : {},
      steps: ready
          ? [
              for (final op in ['resolve', 'analyze', 'test', 'build'])
                GenerationStep(operation: op, exitCode: 0, output: 'fixture'),
            ]
          : [],
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'source HTTP body matches completed proposal identity and fixed ceiling',
    () async {
      final previous = HttpOverrides.current;
      HttpOverrides.global = null;
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      try {
        final observed = Completer<Map<String, dynamic>>();
        server.listen((incoming) async {
          observed.complete(
            jsonDecode(await utf8.decoder.bind(incoming).join())
                as Map<String, dynamic>,
          );
          incoming.response.headers.contentType = ContentType(
            'text',
            'event-stream',
          );
          incoming.response.write(
            'data: ${jsonEncode({
              'choices': [
                {
                  'delta': {'content': response()},
                },
              ],
            })}\n\ndata: [DONE]\n\n',
          );
          await incoming.response.close();
        });
        final records = AtomicRecords();
        await seed(records);
        final failed = boundFailure(records);
        await saveFailure(records, failed);
        final value = await ApprovedSourceProposer(records).propose(
          project: project,
          boardTaskId: 'Tanalyze',
          repairCandidate: failed,
          originals: originals,
          config: LocalModelConfig(
            baseUrl: 'http://127.0.0.1:${server.port}/v1',
            model: 'wire-source',
            chatOutputTokens: 512,
          ),
        );
        final body = await observed.future;
        expect(body['model'], value.modelRequest!.model);
        expect(body['max_tokens'], value.modelRequest!.outputTokens);
        expect(body['max_tokens'], 4096);
        final attempt = RepairAttemptStore(
          records,
          project.id,
        ).load().attempts.single;
        expect(attempt.modelRequest!.model, body['model']);
        expect(attempt.modelRequest!.outputTokens, body['max_tokens']);
        expect(
          value.modelRequest!.toJson().keys,
          unorderedEquals(['version', 'model', 'outputTokens']),
        );
      } finally {
        await server.close(force: true);
        HttpOverrides.global = previous;
      }
    },
  );

  test(
    'settings changes during transport cannot relabel consecutive proposals',
    () async {
      final records = ControlledRecords();
      await seed(records);
      final settings = ModelSettingsStore(records);
      final providers = [FakeProvider(), FakeProvider()];
      var calls = 0;
      final configs = <LocalModelConfig>[];
      final service = ApprovedSourceProposer(
        records,
        proposer: SourceEditProposer(
          createProvider: (config) {
            configs.add(config);
            return providers[calls++];
          },
        ),
      );
      await settings.save(
        const LocalModelConfig(model: 'first', chatOutputTokens: 512),
      );
      final first = service.propose(
        project: project,
        boardTaskId: 'Tanalyze',
        originals: originals,
        config: settings.load(),
      );
      await settings.save(
        const LocalModelConfig(model: 'second', chatOutputTokens: 2048),
      );
      providers.first.stream.add(response());
      await providers.first.stream.close();
      final one = await first;
      final second = service.propose(
        project: project,
        boardTaskId: 'Tanalyze',
        originals: originals,
        config: settings.load(),
      );
      providers.last.stream.add(response());
      await providers.last.stream.close();
      final two = await second;
      expect(configs.map((c) => c.model), ['first', 'second']);
      expect(
        [one.modelRequest!.model, two.modelRequest!.model],
        ['first', 'second'],
      );
      expect(
        [one.modelRequest!.outputTokens, two.modelRequest!.outputTokens],
        [4096, 4096],
      );
    },
  );

  test('native reopen, history and rollback retain candidate metadata; corruption refuses overwrite', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final dir = await Directory.systemTemp.createTemp('asg-source-metadata-');
    final path = '${dir.path}/records.db';
    var db = await databaseFactoryIo.openDatabase(path);
    try {
      var records = await StudioDatabase.migrate(db, preferences);
      var store = SourceGenerationStore(records);
      await store.save('p', candidate(legacy: true, ready: true));
      await store.save('p', candidate(ready: true));
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      records = await StudioDatabase.migrate(db, preferences);
      store = SourceGenerationStore(records);
      expect(store.load('p')!.sourceRequest!.model, 'source-model');
      expect(store.history('p').first.project.sourceRequest, isNull);
      expect(store.history('p').last.project.sourceRequest!.outputTokens, 4096);
      final rollback = jsonDecode(
        store.encodeRollback('p', store.history('p').last),
      ) as Map<String, dynamic>;
      expect(
        GeneratedProject.fromJson(rollback).sourceRequest!.model,
        'source-model',
      );
      expect(
        GeneratedProject.fromJson(
          jsonDecode(store.encodeRollback('p', store.history('p').first))
              as Map<String, dynamic>,
        ).sourceRequest,
        isNull,
      );
      final key = 'studio.generation.v1.p';
      for (final inHistory in [false, true]) {
        final data =
            jsonDecode(records.getString(key)!) as Map<String, dynamic>;
        if (inHistory) {
          ((data['buildHistory'] as List).last['project']
                  as Map)['sourceRequest'] =
              null;
        } else {
          data['sourceRequest'] = {
            'version': 1,
            'model': 'invalid',
            'outputTokens': 512,
          };
        }
        final corrupt = jsonEncode(data);
        await StoreRef<String, String>('records').record(key).put(db, corrupt);
        await db.close();
        db = await databaseFactoryIo.openDatabase(path);
        records = await StudioDatabase.migrate(db, preferences);
        store = SourceGenerationStore(records);
        expect(() => store.load('p'), throwsFormatException);
        await expectLater(
          store.save('p', candidate(ready: true)),
          throwsFormatException,
        );
        expect(
          await StoreRef<String, String>('records').record(key).get(db),
          corrupt,
        );
        // Restore only this synthetic test record for the next corruption case.
        await StoreRef<String, String>('records')
            .record(key)
            .put(db, jsonEncode(rollback));
        await db.close();
        db = await databaseFactoryIo.openDatabase(path);
        records = await StudioDatabase.migrate(db, preferences);
        store = SourceGenerationStore(records);
      }
    } finally {
      await db.close();
      await dir.delete(recursive: true);
    }
  });

  test('legacy records stay unknown; invalid source metadata never grants support or confinement', () {
    final legacy = candidate(legacy: true).toJson();
    expect(legacy.containsKey('sourceRequest'), false);
    expect(
      GeneratedProject.fromJson(legacy).sourceRequestDescription,
      contains('unavailable'),
    );
    for (final invalid in [
      null,
      {},
      {'version': 2, 'model': 'x', 'outputTokens': 4096},
      {'version': 1, 'model': 'x', 'outputTokens': 2048},
      {'version': 1, 'model': 'x', 'outputTokens': 4096, 'endpoint': 'private'},
    ]) {
      expect(
        () => GeneratedProject.fromJson({...legacy, 'sourceRequest': invalid}),
        throwsFormatException,
      );
    }
    final unconfined = candidate().toJson()..remove('confinementVersion');
    expect(() => GeneratedProject.fromJson(unconfined), throwsFormatException);
    expect(
      candidate().copy(phase: SourceGenerationPhase.verifying).sourceRequest,
      same(request),
    );
    expect(candidate().sourceRequestDescription, contains('unverified'));
  });
}
