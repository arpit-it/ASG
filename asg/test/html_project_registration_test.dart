// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/html_export_controller.dart';
import 'package:asg/controllers/requirements_controller.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/views/requirements_screen.dart';
import 'package:asg/controllers/dashboard_controller.dart';
import 'package:asg/controllers/project_details_controller.dart';
import 'package:asg/services/project_details_store.dart';
import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/models/html/saved_html_starter.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/html/html_project_store.dart';
import 'package:asg/services/html/html_source_export.dart';
import 'package:asg/services/html/html_source_export_native.dart';
import 'package:asg/services/html/html_starter_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/dashboard.dart';
import 'package:asg/views/html_export_screen.dart';
import 'package:asg/views/html_project_workspace.dart';
import 'package:asg/views/project_workspace.dart';
import 'package:asg/views/studio_home.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Records implements ConditionalRecordStorage {
  final data = <String, String>{};
  bool fail = false;
  int writes = 0;
  Completer<void>? gate;
  @override
  String? getString(String key) => data[key];
  @override
  Future<bool> setString(String key, String value) async {
    data[key] = value;
    return true;
  }

  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    writes++;
    await gate?.future;
    if (fail || expected.entries.any((e) => data[e.key] != e.value)) {
      throw StateError('Conflict');
    }
    authorize();
    data.addAll(updates);
  }
}

class _Exporter implements HtmlSourceExport {
  @override
  bool get supported => true;
  @override
  Future<String> export({
    required HtmlExportRequest request,
    required HtmlExportRequest? confirmedRequest,
    required void Function() authorizeWrite,
  }) async => throw StateError('Must not export');
}

SavedHtmlStarter starter([String path = '/tmp/site']) => SavedHtmlStarter(
  directory: path,
  input: HtmlSiteInput(
    title: 'Example site',
    description: 'Original fixed starter',
  ),
);
HtmlExportController _controller(_Records records) => HtmlExportController(
  exporter: _Exporter(),
  starterStore: HtmlStarterStore(records),
  savedStarter: starter(),
);

void main() {
  for (final narrow in [false, true]) {
    testWidgets(
      'HTML board retains project-scoped edits without source actions narrow=$narrow',
      (tester) async {
        tester.view.physicalSize = Size(narrow ? 320 : 1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final records = _Records();
        final p = await HtmlProjectStore(records)
            .register(starter(), authorize: () {});
        final original = Map<String, String>.of(records.data);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(narrow ? 2 : 1)),
              child: child!,
            ),
            home: HtmlProjectWorkspace(project: p, records: records),
          ),
        );
        Future<void> openBoard() async {
          final entry = find.widgetWithText(
            OutlinedButton,
            'Requirements and tasks',
          );
          await tester.scrollUntilVisible(
            entry,
            180,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(entry);
          await tester.tap(entry);
          await tester.pumpAndSettle();
        }

        await openBoard();
        expect(records.data, original);
        final board = tester
            .widget<RequirementsScreen>(find.byType(RequirementsScreen))
            .controller;
        expect(
          await board.saveRequirement(
            ProjectRequirement(
              id: 'R1',
              title: 'HTML navigation',
              acceptance: 'Links work using the keyboard.',
            ),
          ),
          true,
        );
        expect(
          await board.saveTask(
            DevelopmentTask(
              id: 'T1',
              title: 'Check navigation',
              requirementId: 'R1',
              dependencies: const [],
              status: TaskStatus.queued,
            ),
          ),
          true,
        );
        await tester.pumpAndSettle();
        await tester.pageBack();
        await tester.pumpAndSettle();
        await openBoard();
        final reopened = tester
            .widget<RequirementsScreen>(find.byType(RequirementsScreen))
            .controller;
        expect(reopened.board!.requirements.single.title, 'HTML navigation');
        expect(reopened.board!.tasks.single.id, 'T1');
        final other = RequirementsController(
          'another-project',
          RequirementsStore(records),
        )..load();
        expect(other.board!.requirements, isEmpty);
        other.dispose();
        for (final entry in original.entries) {
          expect(records.data[entry.key], entry.value);
        }
        expect(records.data.keys.toSet().difference(original.keys.toSet()), {
          RequirementsStore.key(p.id),
        });
        expect(find.text('Requirement check report'), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'HTML board preserves corrupt requirements and allows retry independently of starter metadata',
    (tester) async {
      final records = _Records();
      final p = await HtmlProjectStore(records)
          .register(starter(), authorize: () {});
      records.data[RequirementsStore.key(p.id)] = 'damaged';
      records.data[HtmlStarterStore.key] = 'damaged';
      await tester.pumpWidget(
        MaterialApp(
          home: HtmlProjectWorkspace(project: p, records: records),
        ),
      );
      final entry = find.widgetWithText(
        OutlinedButton,
        'Requirements and tasks',
      );
      await tester.ensureVisible(entry);
      await tester.tap(entry);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Saved requirements are unreadable'),
        findsOneWidget,
      );
      expect(records.data[RequirementsStore.key(p.id)], 'damaged');
      records.data.remove(RequirementsStore.key(p.id));
      await tester.tap(find.text('Retry loading'));
      await tester.pumpAndSettle();
      expect(find.text('No structured requirements yet.'), findsOneWidget);
      expect(records.data[HtmlStarterStore.key], 'damaged');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  test('atomic registration preserves unrelated data; retry deduplicates and resolves original inputs', () async {
    final records = _Records();
    const unrelated = StudioProject(
      id: 'other',
      name: 'Existing',
      description: '',
      type: 'Flutter',
      platforms: ['Web'],
      location: '/tmp/other',
    );
    await StudioStore(records).save([unrelated]);
    final store = HtmlProjectStore(records);
    final p = await store.register(starter(), authorize: () {});
    expect(p.type, 'HTML');
    expect(p.platforms, ['Web']);
    expect(StudioStore(records).load().first.toJson(), unrelated.toJson());
    expect(store.resolve(p).toJson(), starter().toJson());
    expect((await store.register(starter(), authorize: () {})).id, p.id);
    expect(records.writes, 1);
    expect(records.getString('studio.lastProject.v1'), isNull);
    expect(
      records.data.keys,
      unorderedEquals(['studio.projects.v1', HtmlStarterStore.key]),
    );
  });
  test('failure and transaction conflicts preserve both records and allow clean retry', () async {
    final records = _Records()..fail = true;
    final store = HtmlProjectStore(records);
    await expectLater(
      store.register(starter(), authorize: () {}),
      throwsStateError,
    );
    expect(records.data, isEmpty);
    records.fail = false;
    records.gate = Completer();
    final first = store.register(starter(), authorize: () {});
    final second = expectLater(
      store.register(starter('/tmp/second'), authorize: () {}),
      throwsStateError,
    );
    records.gate!.complete();
    await first;
    await second;
    await store.register(starter('/tmp/second'), authorize: () {});
    expect(StudioStore(records).load(), hasLength(2));
    expect(HtmlStarterStore(records).load(), hasLength(2));
  });
  test('corruption, metadata conflicts and wrong-stack destinations never overwrite data', () async {
    final records = _Records();
    final store = HtmlProjectStore(records);
    for (final key in [HtmlStarterStore.key, 'studio.projects.v1']) {
      records.data[key] = 'damaged';
      await expectLater(
        store.register(starter(), authorize: () {}),
        throwsFormatException,
      );
      expect(records.data[key], 'damaged');
      records.data.clear();
    }
    await HtmlStarterStore(records).save(
      SavedHtmlStarter(
        directory: starter().directory,
        input: HtmlSiteInput(title: 'Different', description: 'Different'),
      ),
    );
    final before = Map.of(records.data);
    await expectLater(
      store.register(starter(), authorize: () {}),
      throwsStateError,
    );
    expect(records.data, before);
    records.data.clear();
    await StudioStore(records).save([
      StudioProject(
        id: 'other',
        name: 'Other',
        description: '',
        type: 'Flutter',
        platforms: const ['Web'],
        location: starter().directory,
      ),
    ]);
    final oldProjects = records.getString('studio.projects.v1');
    await expectLater(
      store.register(starter(), authorize: () {}),
      throwsStateError,
    );
    expect(records.getString('studio.projects.v1'), oldProjects);
    expect(records.getString(HtmlStarterStore.key), isNull);
  });
  test('controller registration is explicit, failure retries, concurrent edits blocked, disposal revokes commit', () async {
    final records = _Records()..fail = true;
    final c = _controller(records);
    expect(records.writes, 0);
    await c.registerProject();
    expect(c.registeredProject, isNull);
    expect(c.registrationError, contains('do not export again'));
    expect(c.exportedDirectory, '/tmp/site');
    records.fail = false;
    records.gate = Completer();
    final pending = c.registerProject();
    await c.registerProject();
    await c.saveStarter();
    c.edit(title: 'Ignored');
    c.prepareReview();
    await c.pickParent();
    expect(c.title, 'Example site');
    expect(c.registering, true);
    var notifications = 0;
    c.addListener(() => notifications++);
    c.dispose();
    final before = notifications;
    records.gate!.complete();
    await pending;
    expect(notifications, before);
    expect(records.data, isEmpty);
    final fresh = _controller(records);
    await fresh.registerProject();
    expect(fresh.registeredProject?.type, 'HTML');
    expect(fresh.saved, true);
    expect(fresh.sourceCheck, isNull);
    expect(fresh.preview.url, isNull);
    fresh.edit(title: 'New draft');
    expect(fresh.registeredProject, isNull);
    expect(fresh.exportedDirectory, isNull);
    fresh.dispose();
  });
  test('HTML project metadata edits retain original starter without creating a Flutter prototype', () async {
    final records = _Records();
    final html = HtmlProjectStore(records);
    final original = await html.register(starter(), authorize: () {});
    final editor = ProjectDetailsController(
      original,
      ProjectDetailsStore(StudioStore(records)),
    );
    expect(
      await editor.save('Renamed project', 'Changed project description'),
      true,
    );
    expect(records.getString('studio.application.v1.${original.id}'), isNull);
    expect(html.resolve(editor.project).input.title, 'Example site');
    expect(StudioStore(records).load().single.name, 'Renamed project');
    editor.dispose();
  });
  test(
    'native database close/reopen retains registration without source IO',
    () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final temp = await Directory.systemTemp.createTemp('asg-html-project-');
      addTearDown(() => temp.delete(recursive: true));
      var db = await databaseFactoryIo.openDatabase('${temp.path}/records.db');
      var records = await StudioDatabase.migrate(db, prefs);
      final p = await HtmlProjectStore(records)
          .register(starter(), authorize: () {});
      await db.close();
      db = await databaseFactoryIo.openDatabase('${temp.path}/records.db');
      addTearDown(() => db.close());
      records = await StudioDatabase.migrate(db, prefs);
      expect(HtmlProjectStore(records).resolve(p).input.title, 'Example site');
      expect(StudioStore(records).load().single.id, p.id);
    },
  );
  test('registered real export reopens exact checks and preview; edited sources stay refused', () async {
    final records = _Records();
    final temp = await Directory.systemTemp.createTemp(
      'asg-registered-export-',
    );
    addTearDown(() => temp.delete(recursive: true));
    final parent = await temp.resolveSymbolicLinks();
    final request = HtmlExportRequest(
      input: starter().input,
      parent: parent,
      folderName: 'registered_site',
    );
    final exporter = HtmlSourceExportNative();
    final directory = await exporter.export(
      request: request,
      confirmedRequest: request,
      authorizeWrite: () {},
    );
    final p = await HtmlProjectStore(records).register(
      SavedHtmlStarter(directory: directory, input: request.input),
      authorize: () {},
    );
    final reopened = HtmlExportController(
      exporter: exporter,
      starterStore: HtmlStarterStore(records),
      savedStarter: HtmlProjectStore(records).resolve(p),
    );
    addTearDown(reopened.dispose);
    expect(reopened.sourceCheck, isNull);
    expect(reopened.preview.url, isNull);
    await reopened.checkExport();
    expect(reopened.sourceCheck?.files, 5);
    await reopened.startPreview();
    expect(reopened.preview.error, isNull);
    expect(reopened.preview.url?.host, '127.0.0.1');
    await reopened.preview.stop();
    await File('$directory/app.js').writeAsString('changed');
    await reopened.checkExport();
    expect(reopened.sourceCheck, isNull);
    expect(reopened.checkError, isNotNull);
    await reopened.startPreview();
    expect(reopened.preview.url, isNull);
    expect(reopened.preview.error, isNotNull);
    expect(await File('$directory/app.js').readAsString(), 'changed');
  }, skip: !Platform.isMacOS);
  test('adding from a stale dashboard preserves later HTML registrations and rejects duplicate IDs', () async {
    final records = _Records();
    final store = StudioStore(records);
    final dashboard = DashboardController(store, const []);
    final html = await HtmlProjectStore(records)
        .register(starter(), authorize: () {});
    const flutter = StudioProject(
      id: 'later',
      name: 'Later',
      description: '',
      type: 'Flutter',
      platforms: ['Web'],
      location: '/tmp/later',
    );
    expect(await dashboard.add(flutter), true);
    expect(store.load().map((p) => p.id), [html.id, flutter.id]);
    expect(await dashboard.add(flutter), false);
    expect(store.load().map((p) => p.id), [html.id, flutter.id]);
    dashboard.dispose();
  });
  test('dashboard append refuses corrupt reread and concurrent registration without erasing records', () async {
    final records = _Records();
    final store = StudioStore(records);
    final dashboard = DashboardController(store, const []);
    const flutter = StudioProject(
      id: 'later',
      name: 'Later',
      description: '',
      type: 'Flutter',
      platforms: ['Web'],
      location: '/tmp/later',
    );
    records.data['studio.projects.v1'] = 'damaged';
    expect(await dashboard.add(flutter), false);
    expect(records.getString('studio.projects.v1'), 'damaged');
    expect(records.writes, 0);
    records.data.clear();
    records.gate = Completer();
    final pending = dashboard.add(flutter);
    final registration = expectLater(
      HtmlProjectStore(records).register(starter(), authorize: () {}),
      throwsStateError,
    );
    records.gate!.complete();
    expect(await pending, true);
    await registration;
    await HtmlProjectStore(records).register(starter(), authorize: () {});
    expect(store.load().map((p) => p.type), ['Flutter', 'HTML']);
    dashboard.dispose();
  });
  testWidgets(
    'returning from nested registered HTML workspace refreshes Projects',
    (tester) async {
      final records = _Records();
      final p = await HtmlProjectStore(records)
          .register(starter(), authorize: () {});
      await tester.pumpWidget(
        MaterialApp(
          home: Dashboard(store: StudioStore(records), initialProjects: [p]),
        ),
      );
      await tester.scrollUntilVisible(
        find.widgetWithText(ListTile, 'HTML · Web'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.widgetWithText(ListTile, 'HTML · Web'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(ListTile, 'HTML · Web'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open HTML starter'));
      await tester.pumpAndSettle();
      await HtmlProjectStore(records)
          .register(starter('/tmp/second'), authorize: () {});
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Projects · 2'),
        -200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Projects · 2'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final narrow in [false, true]) {
    testWidgets(
      'register then Projects reopens dedicated HTML workspace narrow=$narrow',
      (tester) async {
        tester.view.physicalSize = Size(narrow ? 320 : 1200, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final records = _Records();
        final c = _controller(records);
        Widget app(Widget home) => MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(narrow ? 2 : 1)),
            child: child!,
          ),
          home: home,
        );
        await tester.pumpWidget(app(HtmlExportScreen(controller: c)));
        final button = find.text('Register HTML starter in Projects');
        await tester.scrollUntilVisible(
          button,
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(button);
        await tester.pumpAndSettle();
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(c.registeredProject, isNotNull);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(
          app(
            Dashboard(
              store: StudioStore(records),
              initialProjects: StudioStore(records).load(),
            ),
          ),
        );
        await tester.pumpAndSettle();
        final projectTile = find.widgetWithText(ListTile, 'HTML · Web');
        await tester.scrollUntilVisible(
          projectTile,
          220,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(projectTile);
        await tester.pumpAndSettle();
        await tester.tap(projectTile);
        await tester.pumpAndSettle();
        expect(find.byType(HtmlProjectWorkspace), findsOneWidget);
        final open = find.text('Open HTML starter');
        await tester.scrollUntilVisible(
          open,
          180,
          scrollable: find.byType(Scrollable).last,
        );
        await tester.ensureVisible(open);
        await tester.tap(open);
        await tester.pumpAndSettle();
        final reopened = tester
            .widget<HtmlExportScreen>(find.byType(HtmlExportScreen))
            .controller;
        expect(reopened.title, 'Example site');
        expect(reopened.preview.url, isNull);
        expect(reopened.sourceCheck, isNull);
        expect(records.writes, 1);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
  testWidgets(
    'home restore routes HTML safely; missing metadata refuses rather than Flutter fallback',
    (tester) async {
      final records = _Records();
      final p = await HtmlProjectStore(records)
          .register(starter(), authorize: () {});
      await tester.pumpWidget(
        MaterialApp(
          home: StudioHome(store: StudioStore(records), projects: [p]),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(HtmlProjectWorkspace), findsOneWidget);
      expect(find.text('Open HTML starter'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      records.data[HtmlStarterStore.key] = jsonEncode([]);
      await tester.pumpWidget(
        MaterialApp(
          home: ProjectWorkspace(project: p, records: records),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('metadata is missing or changed'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Open HTML starter'),
            )
            .onPressed,
        isNull,
      );
      expect(records.writes, 1);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
