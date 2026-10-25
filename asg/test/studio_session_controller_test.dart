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
