// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/html_export_controller.dart';
import 'package:asg/controllers/html_starter_library_controller.dart';
import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/models/html/saved_html_starter.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/services/html/html_source_export.dart';
import 'package:asg/services/html/html_source_export_native.dart';
import 'package:asg/services/html/html_starter_runner.dart';
import 'package:asg/services/html/html_site_template.dart';
import 'package:asg/services/html/html_starter_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/dashboard.dart';
import 'package:asg/views/html_export_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _RealHttpOverrides extends HttpOverrides {}

class _Records implements ConditionalRecordStorage {
  final data = <String, String>{};
  bool fail = false;
  int writes = 0;
  Completer<void>? gate;
  @override
  String? getString(String key) => data[key];
  @override
  Future<bool> setString(String key, String value) async =>
      throw StateError('Use transactions');
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    writes++;
    await gate?.future;
    if (fail || expected.entries.any((e) => data[e.key] != e.value)) {
      throw StateError('write refused');
    }
    authorize();
    data.addAll(updates);
  }
}

class _Picker extends FolderPicker {
  @override
  Future<String?> pick() async => '/tmp';
}

class _Exporter implements HtmlSourceExport {
  @override
  bool get supported => true;
  @override
  Future<String> export({
    required HtmlExportRequest request,
    required HtmlExportRequest? confirmedRequest,
    required void Function() authorizeWrite,
  }) async {
    authorizeWrite();
    return '/tmp/saved_site';
  }
}

SavedHtmlStarter starter([String path = '/tmp/saved_site']) => SavedHtmlStarter(
  directory: path,
  input: HtmlSiteInput(
    title: 'Saved site',
    description: 'Original description',
  ),
);
Future<HtmlExportController> exported(HtmlStarterStore store) async {
  final c = HtmlExportController(
    exporter: _Exporter(),
    starterStore: store,
    folderPicker: _Picker(),
  );
  c.edit(
    title: 'Saved site',
    description: 'Original description',
    folder: 'saved_site',
  );
  await c.pickParent();
  c.prepareReview();
  await c.confirm(c.review!);
  return c;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('typed records reject unknown identities, paths, schemas and unbounded text', () {
    expect(SavedHtmlStarter.adapterId, HtmlSiteTemplate.adapterId);
    expect(SavedHtmlStarter.runnerVersion, HtmlStarterRunner.runnerVersion);
    final value = starter().toJson();
    expect(SavedHtmlStarter.fromJson(value).input.title, 'Saved site');
    for (final change in <Map<String, Object>>[
      {'schemaVersion': 1.0},
      {'schemaVersion': 2},
      {'adapterId': 'other'},
      {'runnerVersion': 'next'},
      {'directory': 'relative'},
      {'directory': '/tmp/../outside'},
      {'directory': '/tmp//site'},
      {'directory': '/tmp/site/'},
      {'title': ''},
      {'description': 'x' * 2001},
      {'unexpected': true},
    ]) {
      expect(
        () => SavedHtmlStarter.fromJson({...value, ...change}),
        throwsFormatException,
      );
    }
  });
  test('corruption and duplicate identities are retained, never overwritten by save', () async {
    final records = _Records();
    final store = HtmlStarterStore(records);
    for (final raw in [
      'bad',
      '{}',
      '[null]',
      jsonEncode([starter().toJson(), starter().toJson()]),
    ]) {
      records.data[HtmlStarterStore.key] = raw;
      expect(store.load, throwsFormatException);
      await expectLater(store.save(starter()), throwsFormatException);
      expect(records.data[HtmlStarterStore.key], raw);
    }
    expect(records.writes, 0);
    final library = HtmlStarterLibraryController(store);
    expect(library.error, contains('retained'));
    records.data.remove(HtmlStarterStore.key);
    library.reload();
    expect(library.error, isNull);
    library.dispose();
  });
  test('concurrent saves cannot lose entries; conflict retry and same-record dedup work', () async {
    final records = _Records()..gate = Completer();
    final a = HtmlStarterStore(records), b = HtmlStarterStore(records);
    final first = a.save(starter());
    final second = expectLater(
      b.save(starter('/tmp/second_site')),
      throwsStateError,
    );
    records.gate!.complete();
    await first;
    await second;
    expect(a.load(), hasLength(1));
    await b.save(starter('/tmp/second_site'));
    await a.save(starter());
    expect(a.load(), hasLength(2));
    expect(records.writes, 3);
    await expectLater(
      a.save(
        SavedHtmlStarter(
          directory: starter().directory,
          input: HtmlSiteInput(title: 'Different', description: 'Different'),
        ),
      ),
      throwsStateError,
    );
    expect(a.load().first.input.title, 'Saved site');
  });
  test('save is explicit; failure retries without export and guards edits/duplicates/disposal', () async {
    final records = _Records()..fail = true;
    final c = await exported(HtmlStarterStore(records));
    expect(records.writes, 0);
    await c.saveStarter();
    expect(c.saved, false);
    expect(c.exportedDirectory, '/tmp/saved_site');
    expect(c.saveError, contains('do not export again'));
    records.fail = false;
    records.gate = Completer();
    final save = c.saveStarter();
    await c.saveStarter();
    c.edit(title: 'Ignored');
    c.prepareReview();
    await c.pickParent();
    expect(c.saving, true);
    expect(c.title, 'Saved site');
    expect(c.exportedDirectory, '/tmp/saved_site');
    var updates = 0;
    c.addListener(() => updates++);
    c.dispose();
    final before = updates;
    records.gate!.complete();
    await save;
    expect(updates, before);
    expect(records.writes, 2);
    expect(HtmlStarterStore(records).load(), hasLength(1));
    final reopened = HtmlExportController(
      exporter: _Exporter(),
      starterStore: HtmlStarterStore(records),
      savedStarter: starter(),
    );
    expect(reopened.saved, true);
    expect(reopened.sourceCheck, isNull);
    expect(reopened.preview.url, isNull);
    expect(reopened.review, isNull);
    reopened.edit(title: 'New site');
    expect(reopened.saved, false);
    expect(reopened.exportedDirectory, isNull);
    reopened.dispose();
  });
  testWidgets(
    '320px/2x dashboard reopens saved starter without writes or automatic checks',
    (tester) async {
      final records = _Records();
      await HtmlStarterStore(records).save(starter());
      final before = records.writes;
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Dashboard(
            store: StudioStore(records),
            initialProjects: const [],
          ),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Saved site'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Saved site'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Saved site'));
      await tester.pumpAndSettle();
      expect(find.byType(HtmlExportScreen), findsOneWidget);
      final screen = tester.widget<HtmlExportScreen>(
        find.byType(HtmlExportScreen),
      );
      expect(screen.controller.title, 'Saved site');
      expect(screen.controller.sourceCheck, isNull);
      expect(screen.controller.preview.url, isNull);
      await tester.scrollUntilVisible(
        find.text('Starter saved in library'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(records.writes, before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'explicit save controls retain export on failure and retry at 320px/2x',
    (tester) async {
      final records = _Records()..fail = true;
      final c = await exported(HtmlStarterStore(records));
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: HtmlExportScreen(controller: c),
        ),
      );
      Future<void> save() async {
        await tester.scrollUntilVisible(
          find.text('Save starter in library'),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(find.text('Save starter in library'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Save starter in library'));
        await tester.pumpAndSettle();
      }

      expect(records.writes, 0);
      await save();
      expect(c.saved, false);
      expect(c.saveError, isNotNull);
      expect(c.exportedDirectory, '/tmp/saved_site');
      records.fail = false;
      await save();
      expect(c.saved, true);
      expect(c.saveError, isNull);
      expect(
        HtmlStarterStore(records).load().single.directory,
        '/tmp/saved_site',
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  test('real durable database and native export reopen, check, serve, stop, refuse edits', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final temp = await Directory.systemTemp.createTemp('asg-library-');
    addTearDown(() => temp.delete(recursive: true));
    final parent = await temp.resolveSymbolicLinks();
    final dbPath = '$parent/library.db';
    var db = await databaseFactoryIo.openDatabase(dbPath);
    var records = await StudioDatabase.migrate(db, prefs);
    final request = HtmlExportRequest(
      input: starter().input,
      parent: parent,
      folderName: 'saved_site',
    );
    final path = await HtmlSourceExportNative().export(
      request: request,
      confirmedRequest: request,
      authorizeWrite: () {},
    );
    await HtmlStarterStore(records)
        .save(SavedHtmlStarter(directory: path, input: request.input));
    await db.close();
    db = await databaseFactoryIo.openDatabase(dbPath);
    records = await StudioDatabase.migrate(db, prefs);
    final saved = HtmlStarterStore(records).load().single;
    final c = HtmlExportController(
      exporter: HtmlSourceExportNative(),
      starterStore: HtmlStarterStore(records),
      savedStarter: saved,
    );
    addTearDown(c.dispose);
    addTearDown(() => db.close());
    await c.checkExport();
    expect(c.sourceCheck?.files, 5);
    await c.startPreview();
    expect(c.preview.error, isNull);
    final client = HttpOverrides.runWithHttpOverrides(
      () => HttpClient(),
      _RealHttpOverrides(),
    );
    addTearDown(() => client.close(force: true));
    final response = await (await client.getUrl(c.preview.url!)).close();
    expect(response.statusCode, 200);
    expect(await utf8.decoder.bind(response).join(), contains('Saved site'));
    await c.preview.stop();
    await File('$path/app.js').writeAsString('changed');
    await c.checkExport();
    expect(c.sourceCheck, isNull);
    expect(c.checkError, isNotNull);
    await c.startPreview();
    expect(c.preview.url, isNull);
    expect(c.preview.error, isNotNull);
    expect(await File('$path/app.js').readAsString(), 'changed');
    expect(StudioStore(records).load(), isEmpty);
    // Damaged library must not block bootstrap or be silently replaced.
    await db.close();
    db = await databaseFactoryIo.openDatabase(dbPath);
    await StoreRef<String, String>('records')
        .record(HtmlStarterStore.key)
        .put(db, 'damaged');
    await db.close();
    db = await databaseFactoryIo.openDatabase(dbPath);
    records = await StudioDatabase.migrate(db, prefs);
    expect(() => HtmlStarterStore(records).load(), throwsFormatException);
    expect(StudioStore(records).load(), isEmpty);
    await expectLater(
      HtmlStarterStore(records).save(saved),
      throwsFormatException,
    );
  }, skip: !Platform.isMacOS);
}
