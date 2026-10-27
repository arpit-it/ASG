import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/models/build_history_entry.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/generation_host_native.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/views/source_generation_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'build_history_test.dart' show result;
import 'source_generation_controller_test.dart'
    show FixtureHost, project, definition;

class AtomicRecords implements ConditionalRecordStorage {
  final values = <String, String>{};
  bool fail = false;
  Object? privateFailure;
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    values[key] = value;
    return true;
  }

  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    authorize();
    if (privateFailure != null) throw privateFailure!;
    if (fail ||
        expected.entries.any((entry) => values[entry.key] != entry.value)) {
      throw StateError('Commit refused');
    }
    values.addAll(updates);
  }
}

void main() {
  late AtomicRecords records;
  late SourceGenerationStore store;
  late FixtureHost oldHost, newHost;
  late SourceGenerationController controller;
  late BuildHistoryEntry selected;
  late GeneratedProject current;
  late String before;
  const key = 'studio.generation.v1.p';
  setUp(() async {
    records = AtomicRecords();
    store = SourceGenerationStore(records);
    await store.save('p', result(SourceGenerationPhase.ready));
    selected = store.history('p').single;
    current = result(SourceGenerationPhase.failed)
        .copy(failedOperation: 'resolve');
    await store.save('p', current);
    before = records.getString(key)!;
    oldHost = FixtureHost();
    newHost = FixtureHost();
    controller = SourceGenerationController(
      project: project,
      definition: definition,
      store: store,
      host: oldHost,
      createRollbackHost: () => newHost,
    );
    await controller.startPreview();
  });
  tearDown(() {
    if (!controller.isDisposed) controller.dispose();
  });
  Future<bool> restore({bool confirmed = true}) => controller.rollback(
    selected,
    expectedWorking: current,
    confirmed: confirmed,
  );
  test('requires confirmation and exact saved successful selection', () async {
    expect(await restore(confirmed: false), isFalse);
    expect(
      await controller.rollback(
        BuildHistoryEntry(
          recordedAt: DateTime.utc(2000),
          project: selected.project,
        ),
        expectedWorking: current,
        confirmed: true,
      ),
      isFalse,
    );
    expect(
      await controller.rollback(
        store.history('p').last,
        expectedWorking: current,
        confirmed: true,
      ),
      isFalse,
    );
    expect(records.getString(key), before);
    expect(oldHost.server, isTrue);
    expect(newHost.server, isFalse);
  });
  test(
    'atomic rollback retains prior record and journal without running commands',
    () async {
      expect(await restore(), isTrue);
      expect(store.load('p')!.toJson(), selected.project.toJson());
      expect(
        jsonDecode(records.getString(key)!)['buildHistory'],
        jsonDecode(before)['buildHistory'],
      );
      expect(records.getString('studio.generationPrevious.v1.p'), before);
      expect(controller.host, newHost);
      expect(controller.preview, isNotNull);
      expect(oldHost.disposed, isTrue);
      expect(newHost.verifications + newHost.generations, 0);
    },
  );
  test(
    'failed preview and failed storage preserve working state and preview',
    () async {
      final preview = controller.preview;
      newHost.previewGate = Completer<Uri>();
      final pending = restore();
      newHost.previewGate!.completeError(
        StateError('Artifacts missing or changed'),
      );
      expect(await pending, isFalse);
      expect(oldHost.server, isTrue);
      expect(controller.preview, preview);
      expect(records.getString(key), before);
      newHost = FixtureHost();
      records.fail = true;
      expect(await restore(), isFalse);
      expect(newHost.disposed, isTrue);
      expect(oldHost.server, isTrue);
      expect(controller.result!.toJson(), current.toJson());
      expect(records.getString(key), before);
      expect(records.getString('studio.generationPrevious.v1.p'), isNull);
    },
  );
  for (final boundary in ['preview', 'storage']) {
    test(
      'rollback $boundary failure is private and retry preserves work',
      () async {
        const marker = 'PRIVATE_PROMPT token=secret /private/workspace';
        final preview = controller.preview;
        if (boundary == 'preview') {
          newHost.previewGate = Completer<Uri>();
        } else {
          records.privateFailure = StateError(marker);
        }
        final pending = restore();
        if (boundary == 'preview') {
          newHost.previewGate!.completeError(StateError(marker));
        }
        expect(await pending, isFalse);
        expect(controller.error, isNot(contains(marker)));
        expect(controller.error, contains('Retry'));
        expect(controller.busy, isFalse);
        expect(controller.preview, preview);
        expect(controller.host, oldHost);
        expect(oldHost.server, isTrue);
        expect(newHost.disposed, isTrue);
        expect(controller.result!.toJson(), current.toJson());
        expect(records.getString(key), before);
        expect(records.getString('studio.generationPrevious.v1.p'), isNull);
        records.privateFailure = null;
        newHost = FixtureHost();
        expect(await restore(), isTrue);
        expect(controller.error, isNull);
      },
    );
  }
  test('disposed rollback failure publishes no private diagnostic', () async {
    newHost.previewGate = Completer<Uri>();
    final pending = restore();
    controller.dispose();
    newHost.previewGate!.completeError(
      StateError('PRIVATE_PROMPT token=secret'),
    );
    expect(await pending, isFalse);
    expect(controller.error, isNull);
    expect(controller.busy, isFalse);
    expect(newHost.disposed, isTrue);
    expect(records.getString(key), before);
  });
  test(
    'changed durable state during preview refuses publication and overlap',
    () async {
      newHost.previewGate = Completer<Uri>();
      final pending = restore();
      expect(controller.busy, isTrue);
      expect(await restore(), isFalse);
      await store.save('p', current.copy(error: 'external change'));
      final changed = records.getString(key);
      newHost.previewGate!.complete(Uri.parse('http://127.0.0.1:1234/new/'));
      expect(await pending, isFalse);
      expect(records.getString(key), changed);
      expect(oldHost.server, isTrue);
      expect(newHost.disposed, isTrue);
    },
  );
  test(
    'disposal during preview prevents durable switch and cleans replacement',
    () async {
      newHost.previewGate = Completer<Uri>();
      final pending = restore();
      controller.dispose();
      newHost.previewGate!.complete(Uri.parse('http://127.0.0.1:1234/new/'));
      expect(await pending, isFalse);
      expect(records.getString(key), before);
      expect(newHost.disposed, isTrue);
    },
  );
  test(
    'actual database reopen retains selected build and displaced work',
    () async {
      final directory = await Directory.systemTemp.createTemp('asg_rollback_');
      final dbPath = '${directory.path}/records.db';
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      var native = await databaseFactoryIo.openDatabase(dbPath);
      try {
        var database = await StudioDatabase.migrate(native, preferences);
        var nativeStore = SourceGenerationStore(database);
        await nativeStore.save('p', selected.project);
        await nativeStore.save('p', current);
        final previous = database.getString(key);
        final nativeController = SourceGenerationController(
          project: project,
          definition: definition,
          store: nativeStore,
          host: FixtureHost(),
          createRollbackHost: FixtureHost.new,
        );
        expect(
          await nativeController.rollback(
            nativeStore.history('p').first,
            expectedWorking: current,
            confirmed: true,
          ),
          isTrue,
        );
        nativeController.dispose();
        await native.close();
        native = await databaseFactoryIo.openDatabase(dbPath);
        database = await StudioDatabase.migrate(native, preferences);
        nativeStore = SourceGenerationStore(database);
        expect(nativeStore.load('p')!.toJson(), selected.project.toJson());
        expect(nativeStore.history('p').length, 2);
        expect(database.getString('studio.generationPrevious.v1.p'), previous);
      } finally {
        await native.close();
        await directory.delete(recursive: true);
      }
    },
  );
  test('native rollback rejects changed missing and linked files then serves saved output', () async {
    HttpOverrides.global = null;
    final temporary = await Directory.systemTemp.createTemp(
      'asg_rollback_files_',
    );
    final root = await temporary.resolveSymbolicLinks();
    final source = File('$root/lib/main.dart');
    final html = File('$root/build/web/index.html');
    final script = File('$root/build/web/main.dart.js');
    await source.parent.create(recursive: true);
    await html.parent.create(recursive: true);
    await source.writeAsString('retained source');
    await html.writeAsString('<base href="/">Restored fixture');
    await script.writeAsString('retained script');
    final saved = GeneratedProject(
      directory: root,
      sdk: '/sdk',
      python: 'python3',
      sources: await NativeGenerationHost.fingerprints(root, source: true),
      outputs: await NativeGenerationHost.fingerprints(
        html.parent.path,
        source: false,
      ),
      phase: SourceGenerationPhase.ready,
      steps: selected.project.steps,
    );
    await store.save('p', saved);
    final chosen = store.history('p').last;
    await store.save('p', current);
    controller.dispose();
    oldHost = FixtureHost();
    controller = SourceGenerationController(
      project: project,
      definition: definition,
      store: store,
      host: oldHost,
      createRollbackHost: NativeGenerationHost.new,
    );
    await controller.startPreview();
    final preserved = records.getString(key);
    Future<bool> rollbackFiles() =>
        controller.rollback(chosen, expectedWorking: current, confirmed: true);
    final client = HttpClient();
    try {
      await source.writeAsString('changed source');
      expect(await rollbackFiles(), isFalse);
      await source.writeAsString('retained source');
      await script.delete();
      expect(await rollbackFiles(), isFalse);
      await Link(script.path).create(source.path);
      expect(await rollbackFiles(), isFalse);
      await Link(script.path).delete();
      await script.writeAsString('retained script');
      expect(records.getString(key), preserved);
      expect(oldHost.server, isTrue);
      expect(await rollbackFiles(), isTrue);
      final response = await (await client.getUrl(controller.preview!)).close();
      expect(response.statusCode, 200);
      expect(await utf8.decodeStream(response), contains('Restored fixture'));
      expect(await source.readAsString(), 'retained source');
      expect(records.getString('studio.generationPrevious.v1.p'), preserved);
    } finally {
      client.close(force: true);
      controller.dispose();
      await temporary.delete(recursive: true);
    }
  });

  testWidgets(
    'visible selection confirms version and preserves work on cancel',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: SourceGenerationScreen(controller: controller)),
      );
      await tester.scrollUntilVisible(
        find.text('Recorded build history'),
        500,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text('Recorded build history')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Recorded build history'));
      await tester.pumpAndSettle();
      final success = find.textContaining(' · ready');
      await Scrollable.ensureVisible(tester.element(success), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(success);
      await tester.pumpAndSettle();
      final select = find
          .widgetWithText(OutlinedButton, 'Select for rollback')
          .last;
      await Scrollable.ensureVisible(tester.element(select), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(select);
      await tester.pumpAndSettle();
      expect(find.text('Restore selected working build?'), findsOneWidget);
      expect(find.textContaining('Current work retained:'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(records.getString(key), before);
      await Scrollable.ensureVisible(tester.element(select), alignment: 0.5);
      await tester.pumpAndSettle();
      await tester.tap(select);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore selected build'));
      await tester.pumpAndSettle();
      expect(store.load('p')!.phase, SourceGenerationPhase.ready);
      expect(records.getString('studio.generationPrevious.v1.p'), before);
    },
  );
}
