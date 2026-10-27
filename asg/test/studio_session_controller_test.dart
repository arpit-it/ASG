// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/studio_session_controller.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/studio_session_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:asg/views/studio_home.dart';
import 'package:asg/views/dashboard.dart';

StudioProject project(String id) => StudioProject(
  id: id,
  name: id,
  description: 'A project',
  type: 'Flutter',
  platforms: const ['Web'],
  location: '',
);

class DelayedRecords implements RecordStorage {
  final values = <String, String>{};
  final writes = <String>[];
  Completer<bool>? pending;
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    writes.add(key);
    final success = await pending!.future;
    if (success) values[key] = value;
    return success;
  }
}

class CreationRecords extends DelayedRecords {
  bool failProjects = false;
  @override
  Future<bool> setString(String key, String value) async {
    writes.add(key);
    final success = key == 'studio.projects.v1'
        ? !failProjects
        : await pending!.future;
    if (success) values[key] = value;
    return success;
  }
}

void main() {
  late DelayedRecords records;
  late StudioSessionController controller;
  final first = project('first');
  final second = project('second');
  setUp(() {
    records = DelayedRecords();
    controller = StudioSessionController(
      StudioSessionStore(StudioStore(records)),
      [first],
    );
  });
  tearDown(() {
    if (!controller.isDisposed) controller.dispose();
  });
  test(
    'selection waits for commit and excludes select/create overlap',
    () async {
      final observed = <bool>[];
      controller.addListener(() => observed.add(controller.busy));
      records.pending = Completer<bool>();
      final selection = controller.select(second);
      expect(controller.busy, isTrue);
      expect(controller.current, same(first));
      await controller.select(first);
      expect(await controller.create(project('third')), isFalse);
      expect(records.writes, ['studio.lastProject.v1']);
      records.pending!.complete(true);
      await selection;
      expect(controller.current, same(second));
      expect(records.values['studio.lastProject.v1'], second.id);
      expect(observed, [true, false]);
    },
  );
  test('failed selection retains current project and allows retry', () async {
    records.pending = Completer<bool>();
    final failed = controller.select(second);
    records.pending!.complete(false);
    await failed;
    expect(controller.current, same(first));
    expect(controller.busy, isFalse);
    expect(controller.error, contains('could not be opened'));
    expect(records.values, isEmpty);
    records.pending = Completer<bool>();
    final retry = controller.select(second);
    expect(controller.error, isNull);
    records.pending!.complete(true);
    await retry;
    expect(controller.current, same(second));
  });
  test('create prevents overlapping selection during project write', () async {
    records.pending = Completer<bool>();
    final creation = controller.create(second);
    await controller.select(first);
    expect(records.writes, ['studio.projects.v1']);
    records.pending!.complete(true);
    expect(await creation, isTrue);
    expect(records.writes, ['studio.projects.v1', 'studio.lastProject.v1']);
    expect(controller.current, same(second));
    expect(controller.busy, isFalse);
  });
  test('disposed selection cannot publish completion or begin work', () async {
    var notifications = 0;
    controller.addListener(() => notifications++);
    records.pending = Completer<bool>();
    final selection = controller.select(second);
    controller.dispose();
    records.pending!.complete(true);
    await selection;
    expect(controller.current, same(first));
    expect(notifications, 1);
    await controller.select(first);
    expect(await controller.create(second), isFalse);
    expect(records.writes, ['studio.lastProject.v1']);
  });
  test('disposal after project save prevents follow-up selection', () async {
    records.pending = Completer<bool>();
    final creation = controller.create(second);
    controller.dispose();
    records.pending!.complete(true);
    expect(await creation, isFalse);
    expect(controller.current, same(first));
    expect(records.writes, ['studio.projects.v1']);
  });
  test('disposed failed selection does not publish an error', () async {
    records.pending = Completer<bool>();
    final selection = controller.select(second);
    controller.dispose();
    records.pending!.completeError(StateError('write failed'));
    await selection;
    expect(controller.error, isNull);
    expect(controller.current, same(first));
  });
  test(
    'partial creation retries only selection and preserves canonical metadata',
    () async {
      final data = CreationRecords();
      data.values['studio.projects.v1'] = jsonEncode([first.toJson()]);
      final c = StudioSessionController(StudioSessionStore(StudioStore(data)), [
        first,
      ]);
      addTearDown(c.dispose);
      data.pending = Completer<bool>()..complete(false);
      expect(await c.create(second), isFalse);
      expect(c.current, same(first));
      expect(c.savedCreation, same(second));
      expect(c.error, contains('was saved but could not be opened'));
      expect(StudioStore(data).load().map((p) => p.id), ['first', 'second']);
      expect(await c.create(project('third')), isFalse);
      await c.retrySavedCreation();
      expect(c.savedCreation, same(second));
      final changed = StudioProject(
        id: second.id,
        name: 'Revised',
        description: 'New requirements',
        type: second.type,
        platforms: second.platforms,
        location: second.location,
      );
      data.values['studio.projects.v1'] = jsonEncode([
        first.toJson(),
        changed.toJson(),
      ]);
      final savedBytes = data.values['studio.projects.v1'];
      data.pending = Completer<bool>();
      final retry = c.retrySavedCreation();
      expect(c.busy, isTrue);
      expect(c.current, same(first));
      await c.retrySavedCreation();
      await c.select(first);
      data.pending!.complete(true);
      await retry;
      expect(c.current!.name, 'Revised');
      expect(c.current!.description, 'New requirements');
      expect(c.savedCreation, isNull);
      expect(c.error, isNull);
      expect(data.values['studio.projects.v1'], savedBytes);
      expect(
        data.writes.where((key) => key == 'studio.projects.v1'),
        hasLength(1),
      );
      expect(
        data.writes.where((key) => key == 'studio.lastProject.v1'),
        hasLength(3),
      );
    },
  );
  test(
    'project save failure and duplicate identity do not select or overwrite',
    () async {
      final data = CreationRecords()..failProjects = true;
      data.values['studio.projects.v1'] = jsonEncode([first.toJson()]);
      final original = data.values['studio.projects.v1'];
      final c = StudioSessionController(StudioSessionStore(StudioStore(data)), [
        first,
      ]);
      addTearDown(c.dispose);
      expect(await c.create(second), isFalse);
      expect(c.savedCreation, isNull);
      expect(c.error, contains('could not be created'));
      expect(data.values['studio.projects.v1'], original);
      data.failProjects = false;
      expect(await c.create(first), isFalse);
      expect(c.error, contains('identity already exists'));
      expect(data.writes, ['studio.projects.v1']);
      expect(c.current, same(first));
    },
  );
  test('missing or duplicate saved identity cannot be retried', () async {
    for (final saved in [
      <StudioProject>[],
      [second, second],
    ]) {
      final data = CreationRecords();
      final c = StudioSessionController(StudioSessionStore(StudioStore(data)), [
        first,
      ]);
      data.pending = Completer<bool>()..complete(false);
      await c.create(second);
      data.values['studio.projects.v1'] = jsonEncode(
        saved.map((p) => p.toJson()).toList(),
      );
      final writes = data.writes.length;
      await c.retrySavedCreation();
      expect(c.current, same(first));
      expect(c.savedCreation, isNotNull);
      expect(c.error, contains('Check Projects'));
      expect(data.writes, hasLength(writes));
      c.dispose();
    }
  });
  test('disposed creation retry cannot publish or start more writes', () async {
    final data = CreationRecords();
    final c = StudioSessionController(StudioSessionStore(StudioStore(data)), [
      first,
    ]);
    data.pending = Completer<bool>()..complete(false);
    await c.create(second);
    data.pending = Completer<bool>();
    final retry = c.retrySavedCreation();
    c.dispose();
    data.pending!.complete(true);
    await retry;
    await c.retrySavedCreation();
    expect(c.current, same(first));
    expect(data.writes, hasLength(3));
  });
  test('opening another saved project dismisses creation recovery', () async {
    final data = CreationRecords();
    final c = StudioSessionController(StudioSessionStore(StudioStore(data)), [
      first,
    ]);
    addTearDown(c.dispose);
    data.pending = Completer<bool>()..complete(false);
    await c.create(second);
    data.pending = Completer<bool>()..complete(true);
    await c.select(first);
    expect(c.savedCreation, isNull);
    expect(c.current, same(first));
    expect(StudioStore(data).load().single.id, second.id);
  });
  testWidgets(
    'home explains saved creation and retries opening without recreating',
    (tester) async {
      final data = CreationRecords();
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      data.pending = Completer<bool>()..complete(false);
      await tester.pumpWidget(
        MaterialApp(
          home: StudioHome(store: StudioStore(data), projects: const []),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('New project'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byType(TextField).first,
        'A daily task planner',
      );
      await tester.tap(find.text('Show my options'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review project'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create project'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('was saved but could not be opened'),
        findsOneWidget,
      );
      expect(StudioStore(data).load(), hasLength(1));
      data.pending = Completer<bool>();
      await tester.tap(find.text('Retry opening saved project'));
      await tester.pump();
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Retry opening saved project'),
            )
            .onPressed,
        isNull,
      );
      data.pending!.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('Retry opening saved project'), findsNothing);
      expect(find.text('Application preview'), findsOneWidget);
      expect(StudioStore(data).load(), hasLength(1));
      expect(
        data.writes.where((key) => key == 'studio.projects.v1'),
        hasLength(1),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('home locks navigation and workspace until selection commits', (
    tester,
  ) async {
    records.values['studio.projects.v1'] = jsonEncode([
      first.toJson(),
      second.toJson(),
    ]);
    await tester.pumpWidget(
      MaterialApp(
        home: StudioHome(store: StudioStore(records), projects: [first]),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Projects'));
    await tester.pumpAndSettle();
    records.pending = Completer<bool>();
    await tester.scrollUntilVisible(
      find.text('second'),
      250,
      scrollable: find
          .descendant(
            of: find.byType(Dashboard),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('second'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Projects',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'New project',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Edit project details',
            ),
          )
          .onPressed,
      isNull,
    );
    expect(
      find.byWidgetPredicate((w) => w is AbsorbPointer && w.absorbing),
      findsWidgets,
    );
    expect(
      find.byWidgetPredicate((w) => w is ExcludeFocus && w.excluding),
      findsWidgets,
    );
    records.pending!.complete(true);
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<IconButton>(
            find.byWidgetPredicate(
              (w) => w is IconButton && w.tooltip == 'Projects',
            ),
          )
          .onPressed,
      isNotNull,
    );
    expect(find.text('second'), findsWidgets);
    await tester.pumpWidget(const SizedBox());
  });
}
