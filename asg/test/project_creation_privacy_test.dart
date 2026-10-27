import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:asg/views/dashboard.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/controllers/dashboard_controller.dart';
import 'package:asg/controllers/project_wizard_controller.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/services/studio_store.dart';

const project = StudioProject(
  id: 'private',
  name: 'Planner',
  description: 'Tasks',
  type: 'Flutter',
  platforms: ['Web'],
  location: '',
);

class Picker extends FolderPicker {
  @override
  bool get supported => true;
  bool fail = true;
  Completer<String?>? pending;
  @override
  Future<String?> pick() async {
    if (pending != null) return pending!.future;
    if (fail) throw StateError('PRIVATE_PROMPT token=secret /private/folder');
    return '/selected';
  }
}

class Store extends StudioStore {
  Store(super.preferences) : super.fromPreferences();
  bool fail = true;
  Completer<void>? pending;
  @override
  Future<void> save(List<StudioProject> projects) async {
    if (pending != null) return pending!.future;
    if (fail) throw StateError('PRIVATE_PROMPT token=secret /private/record');
    await super.save(projects);
  }
}

void privateError(String? error) {
  expect(error, isNotNull);
  for (final marker in ['PRIVATE_PROMPT', 'token=secret', '/private/']) {
    expect(error, isNot(contains(marker)));
  }
}

void main() {
  testWidgets('dashboard folder failure shows private recovery guidance', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final picker = Picker();
    final store = StudioStore.fromPreferences(
      await SharedPreferences.getInstance(),
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Dashboard(
          store: store,
          initialProjects: const [],
          folderPicker: picker,
        ),
      ),
    );
    await tester.tap(find.text('Open folder'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Unable to open folder.'), findsOneWidget);
    expect(find.textContaining('PRIVATE_PROMPT'), findsNothing);
    expect(find.textContaining('/private/'), findsNothing);
    picker.fail = false;
    await tester.tap(find.text('Open folder'));
    await tester.pumpAndSettle();
    expect(find.text('Folder selected'), findsOneWidget);
    expect(find.textContaining('/selected'), findsOneWidget);
  });
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'failed creation retains saved projects and recovers on retry',
    () async {
      final store = Store(await SharedPreferences.getInstance());
      final c = DashboardController(store, []);
      for (var i = 0; i < 2; i++) {
        expect(await c.add(project), isFalse);
        privateError(c.error);
        expect(c.projects, isEmpty);
        expect(store.load(), isEmpty);
        expect(c.busy, isFalse);
      }
      store.fail = false;
      expect(await c.add(project), isTrue);
      expect(c.error, isNull);
      expect(store.load().single.id, project.id);
      c.dispose();
    },
  );
  test('failed folder selection retains choices and retries cleanly', () async {
    final picker = Picker();
    final c = ProjectWizardController(picker: picker)..location = '/original';
    c.discover('Build a private task planner');
    final idea = c.idea;
    for (var i = 0; i < 2; i++) {
      await c.chooseFolder();
      privateError(c.error);
      expect(c.location, '/original');
      expect(c.idea, idea);
    }
    picker.fail = false;
    await c.chooseFolder();
    expect(c.location, '/selected');
    expect(c.error, isNull);
    c.dispose();
  });
  test('disposed save failure emits no late error or notification', () async {
    final store = Store(await SharedPreferences.getInstance())
      ..pending = Completer<void>();
    final c = DashboardController(store, []);
    var notifications = 0;
    c.addListener(() => notifications++);
    final work = c.add(project);
    c.dispose();
    final before = notifications;
    store.pending!.completeError(StateError('PRIVATE_PROMPT'));
    expect(await work, isFalse);
    expect(c.error, isNull);
    expect(notifications, before);
  });
  test('disposed folder failure emits no late error or notification', () async {
    final picker = Picker()..pending = Completer<String?>();
    final c = ProjectWizardController(picker: picker)..location = '/original';
    var notifications = 0;
    c.addListener(() => notifications++);
    final work = c.chooseFolder();
    c.dispose();
    final before = notifications;
    picker.pending!.completeError(StateError('PRIVATE_PROMPT'));
    await work;
    expect(c.error, isNull);
    expect(c.location, '/original');
    expect(notifications, before);
  });
}
