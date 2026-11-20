// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/imported_advisory_controller.dart';
import 'package:asg/models/imported_advisory_record.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/imported_advisory_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'project_source_controller_test.dart' show sourceReply;

import 'package:asg/models/imported_source_context.dart';
import 'package:asg/models/project_source_observation.dart';

import 'imported_plan_test.dart' show Records, finding, capturedPlan;

class AdvisoryProvider implements ModelResponseIdentityProvider {
  Stream<String>? source;
  String text = 'Synthetic advisory answer';
  String? identity = LocalModelConfig.defaultModel;
  Completer<void>? closing;
  bool failClose = false;
  int calls = 0, cancels = 0;
  String? prompt;
  @override
  String? get completedResponseModel => identity;
  @override
  Stream<String> generate(String value) {
    calls++;
    prompt = value;
    return source ?? Stream.value(text);
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (failClose) throw StateError('private-close');
    await closing?.future;
  }
}

ImportedSourceContext capturedSource() => ImportedSourceContext.capture(
  inspection: finding(),
  requirements: RequirementsBoard(),
  request: ProjectSourceReadRequest(
    root: '/project',
    python: '/python',
    selectedPaths: ['lib/main.dart'],
  ),
  observation: sourceReply(['lib/main.dart']),
);

Future<ImportedAdvisoryController> controller(
  RecordStorage records,
  AdvisoryProvider p, {
  bool source = false,
  Duration timeout = const Duration(seconds: 1),
  Duration cleanup = const Duration(seconds: 2),
}) async {
  await InspectedFolderStore(records).save('/project');
  return ImportedAdvisoryController(
    inspection: finding(),
    context: source
        ? capturedSource()
        : capturedPlan(text: 'PRIVATE_SYNTHETIC_DOCUMENT'),
    store: ImportedAdvisoryStore(records),
    createProvider: (_) => p,
    requestLimit: timeout,
    cleanupLimit: cleanup,
  )..load();
}

Future<void> tick() => Future<void>.delayed(Duration.zero);
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final identity in <String?>[null, 'wrong-source-fixture']) {
    test('source response identity refusal $identity', () async {
      final p = AdvisoryProvider()..identity = identity;
      final c = await controller(Records(), p, source: true);
      addTearDown(c.dispose);
      await c.ask('Explain source', confirm: (_) async => true);
      expect(c.saved, isNull);
      expect(c.unsaved, isNull);
      expect(c.error, isNotNull);
    });
  }
  test('source advisory requires separate consent and stores provenance without source plaintext', () async {
    final records = Records(), p = AdvisoryProvider();
    final c = await controller(records, p, source: true);
    addTearDown(c.dispose);
    final writes = records.writes;
    await c.ask('Explain source', confirm: (_) async => false);
    expect(p.calls, 0);
    expect(records.writes, writes);
    await c.ask(
      'Explain source',
      confirm: (request) async {
        expect(request.context.includesSource, true);
        expect(request.contextDigest, capturedSource().digest);
        expect(request.prompt, contains('Captured source text'));
        expect(p.calls, 0);
        return true;
      },
    );
    expect(c.error, isNull);
    expect(p.calls, 1);
    expect(p.prompt, contains('captured-imported-source-context'));
    final raw = c.saved!.encode();
    expect(raw, isNot(contains('Untrusted [lib/main.dart]')));
    expect(c.saved!.contextDigest, capturedSource().digest);
    final reopened = await controller(
      records,
      AdvisoryProvider(),
      source: true,
    );
    expect(reopened.saved!.encode(), raw);
    reopened.dispose();
  });
  test('source settings changed during consent refuse dispatch and keep previous answer', () async {
    final records = Records(), p = AdvisoryProvider();
    final c = await controller(records, p, source: true);
    addTearDown(c.dispose);
    await c.ask('First', confirm: (_) async => true);
    final old = c.saved!.encode();
    await c.ask(
      'Changed',
      confirm: (_) async {
        await ModelSettingsStore(records)
            .save(const LocalModelConfig(model: 'changed-fixture'));
        return true;
      },
    );
    expect(p.calls, 1);
    expect(c.saved!.encode(), old);
    expect(c.error, isNotNull);
  });
  test('explicit question stores only completed advisory provenance in an isolated key', () async {
    final records = Records(), p = AdvisoryProvider();
    final owner = await controller(records, p);
    addTearDown(owner.dispose);
    final before = records.writes;
    await owner.ask(
      'Explain constraints',
      confirm: (r) async {
        expect(r.config.model, LocalModelConfig.defaultModel);
        expect(r.contextDigest, owner.context.digest);
        expect(records.writes, before);
        expect(p.calls, 0);
        return true;
      },
    );
    expect(owner.error, isNull);
    expect(owner.saved!.answer, p.text);
    expect(owner.saved!.question, 'Explain constraints');
    expect(p.calls, 1);
    expect(p.cancels, 1);
    expect(p.prompt, contains('PRIVATE_SYNTHETIC_DOCUMENT'));
    final raw = records.values[ImportedAdvisoryStore.key('/project')]!;
    expect(raw, isNot(contains('PRIVATE_SYNTHETIC_DOCUMENT')));
    expect(
      records.values.keys.where(
        (k) => k.contains('planApproval') || k.contains('importedPlan'),
      ),
      isEmpty,
    );
    final reopened = await controller(records, AdvisoryProvider());
    expect(reopened.saved!.encode(), raw);
    reopened.dispose();
  });
  test(
    'cancel consent performs no provider construction or record write',
    () async {
      final records = Records(),
          p = AdvisoryProvider(),
          c = await controller(Records(), AdvisoryProvider());
      c.dispose();
      var factories = 0;
      await InspectedFolderStore(records).save('/project');
      final owner = ImportedAdvisoryController(
        inspection: finding(),
        context: capturedPlan(),
        store: ImportedAdvisoryStore(records),
        createProvider: (_) {
          factories++;
          return p;
        },
      )..load();
      addTearDown(owner.dispose);
      final writes = records.writes;
      await owner.ask('Question', confirm: (_) async => false);
      expect(factories, 0);
      expect(records.writes, writes);
      expect(owner.busy, false);
    },
  );
  for (final change in ['requirements', 'model', 'folder']) {
    test('changed $change during consent prevents dispatch', () async {
      final records = Records(),
          p = AdvisoryProvider(),
          c = await controller(records, p);
      addTearDown(c.dispose);
      await c.ask(
        'Question',
        confirm: (_) async {
          if (change == 'model') {
            await ModelSettingsStore(records)
                .save(const LocalModelConfig(chatOutputTokens: 512));
          } else if (change == 'folder') {
            records.values[InspectedFolderStore.key] = '[]';
          } else {
            final s = RequirementsStore(records),
                id = InspectedFolderStore.workspaceId('/project');
            await s.save(id, s.load(id), RequirementsBoard());
          }
          return true;
        },
      );
      expect(p.calls, 0);
      expect(c.saved, isNull);
      expect(c.error, isNotNull);
    });
  }
  for (final identity in <String?>[null, 'wrong-fixture']) {
    test(
      'missing or mismatched response identity never becomes saved answer: $identity',
      () async {
        final records = Records(),
            p = AdvisoryProvider()..identity = identity,
            c = await controller(records, p);
        addTearDown(c.dispose);
        await c.ask('Question', confirm: (_) async => true);
        expect(p.calls, 1);
        expect(c.saved, isNull);
        expect(c.unsaved, isNull);
        expect(c.error, isNotNull);
        expect(c.draft, isEmpty);
        expect(records.values[ImportedAdvisoryStore.key('/project')], isNull);
      },
    );
  }
  test(
    'failed save retains completed answer and retries without inference',
    () async {
      final records = Records(),
          p = AdvisoryProvider(),
          c = await controller(records, p);
      addTearDown(c.dispose);
      records.fail = true;
      await c.ask('Question', confirm: (_) async => true);
      expect(c.saved, isNull);
      expect(c.unsaved!.answer, p.text);
      expect(c.error, isNotNull);
      expect(p.calls, 1);
      records.fail = false;
      await c.retrySaving();
      expect(c.error, isNull);
      expect(c.saved!.answer, p.text);
      expect(c.unsaved, isNull);
      expect(p.calls, 1);
    },
  );
  test(
    'source failed save retains completed answer and retries without inference',
    () async {
      final records = Records(),
          p = AdvisoryProvider(),
          c = await controller(records, p, source: true);
      addTearDown(c.dispose);
      records.fail = true;
      await c.ask('Question', confirm: (_) async => true);
      expect(c.saved, isNull);
      expect(c.unsaved!.answer, p.text);
      expect(c.error, isNotNull);
      expect(p.calls, 1);
      records.fail = false;
      await c.retrySaving();
      expect(c.error, isNull);
      expect(c.saved!.answer, p.text);
      expect(c.unsaved, isNull);
      expect(p.calls, 1);
    },
  );
  test(
    'stale editor preserves first answer and refuses a second request',
    () async {
      final records = Records(),
          p = AdvisoryProvider(),
          first = await controller(records, p),
          otherProvider = AdvisoryProvider(),
          second = await controller(records, otherProvider);
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      await first.ask('First', confirm: (_) async => true);
      final raw = records.values[ImportedAdvisoryStore.key('/project')];
      await second.ask('Second', confirm: (_) async => true);
      expect(otherProvider.calls, 0);
      expect(second.error, isNotNull);
      expect(records.values[ImportedAdvisoryStore.key('/project')], raw);
    },
  );
  test('Stop discards partial response, closes app connection and retains saved answer', () async {
    final records = Records(),
        p = AdvisoryProvider(),
        c = await controller(records, p);
    addTearDown(c.dispose);
    await c.ask('First', confirm: (_) async => true);
    final raw = records.values[ImportedAdvisoryStore.key('/project')];
    final stream = StreamController<String>();
    p.source = stream.stream;
    final asking = c.ask('Next', confirm: (_) async => true);
    await tick();
    stream.add('Partial');
    await tick();
    expect(c.draft, 'Partial');
    c.stop();
    await asking;
    expect(c.draft, isEmpty);
    expect(c.error, contains('Stopped'));
    expect(records.values[ImportedAdvisoryStore.key('/project')], raw);
    expect(c.busy, false);
    await stream.close();
  });
  test('source Stop discards partial response, closes app connection and retains saved answer', () async {
    final records = Records(),
        p = AdvisoryProvider(),
        c = await controller(records, p, source: true);
    addTearDown(c.dispose);
    await c.ask('First', confirm: (_) async => true);
    final raw = records.values[ImportedAdvisoryStore.key('/project')];
    final stream = StreamController<String>();
    p.source = stream.stream;
    final asking = c.ask('Next', confirm: (_) async => true);
    await tick();
    stream.add('Partial');
    await tick();
    expect(c.draft, 'Partial');
    c.stop();
    await asking;
    expect(c.draft, isEmpty);
    expect(c.error, contains('Stopped'));
    expect(records.values[ImportedAdvisoryStore.key('/project')], raw);
    expect(c.busy, false);
    await stream.close();
  });
  test(
    'timeout privately discards partial text and releases only after cleanup',
    () async {
      final records = Records(),
          stream = StreamController<String>(),
          p = AdvisoryProvider()..source = stream.stream;
      final c = await controller(
        records,
        p,
        timeout: const Duration(milliseconds: 15),
      );
      addTearDown(c.dispose);
      final asking = c.ask('Question', confirm: (_) async => true);
      await tick();
      stream.add('private-partial');
      await asking;
      expect(c.saved, isNull);
      expect(c.draft, isEmpty);
      expect(c.error, isNot(contains('private-partial')));
      expect(p.cancels, 1);
      expect(c.canAsk, true);
      await stream.close();
    },
  );
  test('disposed pending confirmation never dispatches and synchronous listener disposal is safe', () async {
    final records = Records(),
        p = AdvisoryProvider(),
        c = await controller(records, p),
        consent = Completer<bool>();
    final asking = c.ask('Question', confirm: (_) => consent.future);
    c.dispose();
    consent.complete(true);
    await asking;
    expect(p.calls, 0);
    expect(c.saved, isNull);
    final next = await controller(records, p);
    next.addListener(next.dispose);
    await next.ask('Question', confirm: (_) async => true);
    expect(p.calls, 0);
    expect(next.isDisposed, true);
  });
  test('cleanup uncertainty retains ownership and explicit retry can recover after disposal', () async {
    final records = Records(),
        p = AdvisoryProvider()..closing = Completer<void>(),
        c = await controller(records, p);
    await c.ask('Question', confirm: (_) async => true);
    expect(c.cleanupUncertain, true);
    expect(c.canAsk, false);
    c.dispose();
    await tick();
    final other = AdvisoryProvider(), next = await controller(records, other);
    addTearDown(next.dispose);
    await next.ask('Next', confirm: (_) async => true);
    expect(other.calls, 0);
    expect(next.canRetryStop, true);
    p.closing!.complete();
    await next.retryStop();
    await next.ask('Next', confirm: (_) async => true);
    expect(other.calls, 1);
  });
  test('transport failure overflow and input changes never replace the last record', () async {
    final records = Records(),
        p = AdvisoryProvider(),
        c = await controller(records, p);
    addTearDown(c.dispose);
    await c.ask('First', confirm: (_) async => true);
    final raw = records.values[ImportedAdvisoryStore.key('/project')];
    p.source = Stream.error(StateError('private-sentinel'));
    await c.ask('Next', confirm: (_) async => true);
    expect(c.error, isNot(contains('private-sentinel')));
    p.source = null;
    p.text = 'x' * (ImportedAdvisoryRecord.answerLimit + 1);
    await c.ask('Next', confirm: (_) async => true);
    expect(records.values[ImportedAdvisoryStore.key('/project')], raw);
    expect(c.unsaved, isNull);
    final stream = StreamController<String>();
    p.source = stream.stream;
    final asking = c.ask('Next', confirm: (_) async => true);
    await tick();
    final s = RequirementsStore(records),
        id = InspectedFolderStore.workspaceId('/project');
    await s.save(id, s.load(id), RequirementsBoard());
    stream.add('Answer on stale inputs');
    await stream.close();
    await asking;
    expect(records.values[ImportedAdvisoryStore.key('/project')], raw);
    expect(c.unsaved, isNull);
  });
  test('strict record refuses extra keys duplicate members identity mismatch and storage-key mismatch', () async {
    final records = Records(),
        p = AdvisoryProvider(),
        c = await controller(records, p);
    addTearDown(c.dispose);
    await c.ask('Question', confirm: (_) async => true);
    final raw = c.saved!.encode(),
        data = jsonDecode(raw) as Map<String, dynamic>;
    for (final changed in [
      {...data, 'authority': true},
      {...data, 'responseModel': 'other'},
      {...data, 'outputTokens': 1},
      {...data, 'endpoint': 'https://external.invalid/v1/'},
    ]) {
      expect(
        () => ImportedAdvisoryRecord.decode(jsonEncode(changed)),
        throwsFormatException,
      );
    }
    expect(
      () =>
          ImportedAdvisoryRecord.decode(raw.replaceFirst('{', '{"version":1,')),
      throwsFormatException,
    );
    expect(
      () => StudioDatabase.validate(ImportedAdvisoryStore.key('/other'), raw),
      throwsFormatException,
    );
  });
  test('actual native database reopen retains answer and stale durable settings reject dispatch', () async {
    final directory = await Directory.systemTemp.createTemp(
      'asg-imported-advisory-',
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase(
      '${directory.path}/records.db',
    );
    try {
      final records = await StudioDatabase.migrate(db, prefs),
          p = AdvisoryProvider(),
          c = await controller(records, p);
      await c.ask('Question', confirm: (_) async => true);
      expect(c.error, isNull);
      final raw = c.saved!.encode();
      c.dispose();
      await db.close();
      db = await databaseFactoryIo.openDatabase('${directory.path}/records.db');
      final reopened = await StudioDatabase.migrate(db, prefs),
          nextProvider = AdvisoryProvider(),
          next = await controller(reopened, nextProvider);
      expect(next.saved!.encode(), raw);
      await StoreRef<String, String>('records')
          .record('studio.localModel.v1')
          .put(
            db,
            jsonEncode({
              'baseUrl': 'http://127.0.0.1:8765/v1',
              'model': LocalModelConfig.defaultModel,
              'chatOutputTokens': 512,
            }),
          );
      await next.ask('Next', confirm: (_) async => true);
      expect(nextProvider.calls, 0);
      expect(next.error, isNotNull);
      expect(reopened.getString(ImportedAdvisoryStore.key('/project')), raw);
      next.dispose();
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });
  test('source actual native database reopen retains answer and stale durable settings reject dispatch', () async {
    final directory = await Directory.systemTemp.createTemp(
      'asg-imported-advisory-',
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase(
      '${directory.path}/records.db',
    );
    try {
      final records = await StudioDatabase.migrate(db, prefs),
          p = AdvisoryProvider(),
          c = await controller(records, p, source: true);
      await c.ask('Question', confirm: (_) async => true);
      expect(c.error, isNull);
      final raw = c.saved!.encode();
      c.dispose();
      await db.close();
      db = await databaseFactoryIo.openDatabase('${directory.path}/records.db');
      final reopened = await StudioDatabase.migrate(db, prefs),
          nextProvider = AdvisoryProvider(),
          next = await controller(reopened, nextProvider, source: true);
      expect(next.saved!.encode(), raw);
      await StoreRef<String, String>('records')
          .record('studio.localModel.v1')
          .put(
            db,
            jsonEncode({
              'baseUrl': 'http://127.0.0.1:8765/v1',
              'model': LocalModelConfig.defaultModel,
              'chatOutputTokens': 512,
            }),
          );
      await next.ask('Next', confirm: (_) async => true);
      expect(nextProvider.calls, 0);
      expect(next.error, isNotNull);
      expect(reopened.getString(ImportedAdvisoryStore.key('/project')), raw);
      next.dispose();
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });
  test('disposed save notification prevents publication and keeps previous durable answer', () async {
    final records = Records(),
        p = AdvisoryProvider(),
        c = await controller(records, p);
    await c.ask('First', confirm: (_) async => true);
    final raw = records.values[ImportedAdvisoryStore.key('/project')];
    c.addListener(() {
      if (c.saving) c.dispose();
    });
    await c.ask('Second', confirm: (_) async => true);
    expect(c.isDisposed, true);
    expect(records.values[ImportedAdvisoryStore.key('/project')], raw);
  });
  test('corrupt native advisory record is quarantined without blocking unrelated records', () async {
    final directory = await Directory.systemTemp.createTemp(
      'asg-advisory-corrupt-',
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = await databaseFactoryIo.openDatabase(
      '${directory.path}/records.db',
    );
    try {
      await StudioDatabase.migrate(db, prefs);
      final key = ImportedAdvisoryStore.key('/project');
      await StoreRef<String, String>('records')
          .record(key)
          .put(db, 'private-corrupt-record');
      final reopened = await StudioDatabase.migrate(db, prefs),
          p = AdvisoryProvider();
      final c = await controller(reopened, p);
      expect(c.ready, false);
      expect(c.error, isNot(contains('private-corrupt-record')));
      await c.ask('Question', confirm: (_) async => true);
      expect(p.calls, 0);
      expect(
        await StoreRef<String, String>('records').record(key).get(db),
        'private-corrupt-record',
      );
      expect(InspectedFolderStore(reopened).load(), contains('/project'));
      c.dispose();
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });
  test('durable input change after dispatch rejects completed-answer commit despite unchanged cache', () async {
    final directory = await Directory.systemTemp.createTemp(
      'asg-advisory-cas-',
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final db = await databaseFactoryIo.openDatabase(
      '${directory.path}/records.db',
    );
    try {
      final records = await StudioDatabase.migrate(db, prefs),
          p = AdvisoryProvider(),
          c = await controller(records, p);
      await c.ask('First', confirm: (_) async => true);
      final raw = c.saved!.encode();
      final stream = StreamController<String>();
      p.source = stream.stream;
      final asking = c.ask('Next', confirm: (_) async => true);
      while (p.calls < 2) {
        await tick();
      }
      await StoreRef<String, String>('records')
          .record('studio.localModel.v1')
          .put(
            db,
            jsonEncode({
              'baseUrl': 'http://127.0.0.1:8765/v1',
              'model': LocalModelConfig.defaultModel,
              'chatOutputTokens': 512,
            }),
          );
      stream.add('Historical response');
      await stream.close();
      await asking;
      expect(c.saved!.encode(), raw);
      expect(c.unsaved!.answer, 'Historical response');
      expect(c.error, isNotNull);
      expect(
        await StoreRef<String, String>('records')
            .record(ImportedAdvisoryStore.key('/project'))
            .get(db),
        raw,
      );
      await c.retrySaving();
      expect(c.unsaved, isNotNull);
      expect(p.calls, 2);
      c.discardUnsaved();
      expect(c.unsaved, isNull);
      c.dispose();
    } finally {
      await db.close();
      await directory.delete(recursive: true);
    }
  });
}
