import 'dart:async';

import 'package:asg/controllers/project_inspection_controller.dart';
import 'package:asg/models/project_inspection.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/views/project_inspection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class Picker extends FolderPicker {
  Future<String?> Function() select = () async => '/project';
  bool available = true;
  int calls = 0;
  @override
  bool get supported => available;
  @override
  Future<String?> pick() {
    calls++;
    return select();
  }
}

ProjectInspection result(String root) => ProjectInspection(
  root: root,
  packageName: 'sample',
  dartSdk: '^3.9.0',
  runners: ['web'],
);
void main() {
  test(
    'overlap excluded, cancel retains observations, picker failure recovers',
    () async {
      final picker = Picker();
      final pending = Completer<ProjectInspection>();
      final c = ProjectInspectionController(
        picker: picker,
        inspect: (_) => pending.future,
      );
      final work = c.chooseFolder();
      await Future<void>.delayed(Duration.zero);
      await c.chooseFolder();
      expect(picker.calls, 1);
      expect(c.busy, isTrue);
      pending.complete(result('/project'));
      await work;
      picker.select = () async => null;
      await c.chooseFolder();
      expect(c.findings?.root, '/project');
      picker.select = () async => throw StateError('picker unavailable');
      await c.chooseFolder();
      expect(c.error, contains('picker unavailable'));
      expect(c.busy, isFalse);
      c.dispose();
    },
  );
  test('invalid selection clears findings; retry succeeds', () async {
    var fail = false;
    final c = ProjectInspectionController(
      picker: Picker(),
      inspect: (path) async {
        if (fail) throw const FormatException('Invalid folder');
        return result(path);
      },
    );
    await c.chooseFolder();
    fail = true;
    await c.chooseFolder();
    expect(c.findings, isNull);
    expect(c.error, contains('Invalid folder'));
    fail = false;
    await c.chooseFolder();
    expect(c.error, isNull);
    expect(c.findings, isNotNull);
    c.dispose();
  });
  test('unsupported platform and disposal prevent inspection', () async {
    final picker = Picker()..available = false;
    var calls = 0;
    final c = ProjectInspectionController(
      picker: picker,
      inspect: (path) async {
        calls++;
        return result(path);
      },
    );
    await c.chooseFolder();
    expect(picker.calls, 0);
    expect(c.error, contains('unavailable'));
    picker.available = true;
    final pending = Completer<String?>();
    picker.select = () => pending.future;
    final work = c.chooseFolder();
    c.dispose();
    pending.complete('/project');
    await work;
    expect(calls, 0);
    await c.chooseFolder();
    expect(picker.calls, 1);
  });
  test('disposal ignores late findings', () async {
    final pending = Completer<ProjectInspection>();
    final c = ProjectInspectionController(
      picker: Picker(),
      inspect: (_) => pending.future,
    );
    final work = c.chooseFolder();
    await Future<void>.delayed(Duration.zero);
    c.dispose();
    pending.complete(result('/project'));
    await work;
    expect(c.findings, isNull);
  });
  test(
    'workspace entry requires saved folder and fresh successful inspection',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = InspectedFolderStore(
        PreferenceRecords(await SharedPreferences.getInstance()),
      );
      var reads = 0;
      var missing = false;
      final c = ProjectInspectionController(
        store: store,
        picker: Picker(),
        inspect: (root) async {
          reads++;
          if (missing) throw const FormatException('Folder missing');
          return result(root);
        },
      );
      expect(await c.openWorkspace(), isNull);
      await c.chooseFolder();
      expect(await c.openWorkspace(), isNull);
      expect(reads, 1);
      await c.saveFolder();
      expect(c.canOpenWorkspace, isTrue);
      expect((await c.openWorkspace())?.root, '/project');
      expect(reads, 2);
      missing = true;
      expect(await c.openWorkspace(), isNull);
      expect(c.findings, isNull);
      expect(c.canOpenWorkspace, isFalse);
      expect(c.error, contains('missing'));
      expect(store.load(), ['/project']);
      c.dispose();
    },
  );
  test(
    'workspace entry excludes overlapping work and ignores disposal',
    () async {
      SharedPreferences.setMockInitialValues({});
      final store = InspectedFolderStore(
        PreferenceRecords(await SharedPreferences.getInstance()),
      );
      await store.save('/project');
      Completer<ProjectInspection>? pending;
      var reads = 0;
      final picker = Picker();
      final c = ProjectInspectionController(
        store: store,
        picker: picker,
        inspect: (root) async {
          reads++;
          return pending == null ? result(root) : pending.future;
        },
      );
      await c.reopen('/project');
      pending = Completer<ProjectInspection>();
      final opening = c.openWorkspace();
      expect(c.busy, isTrue);
      expect(await c.openWorkspace(), isNull);
      await c.chooseFolder();
      await c.saveFolder();
      expect(picker.calls, 0);
      expect(reads, 2);
      c.dispose();
      pending.complete(result('/project'));
      expect(await opening, isNull);
      expect(await c.openWorkspace(), isNull);
    },
  );
  testWidgets(
    'imported workspace edits and reopens its isolated requirements',
    (tester) async {
      SharedPreferences.setMockInitialValues({});
      final store = InspectedFolderStore(
        PreferenceRecords(await SharedPreferences.getInstance()),
      );
      await store.save('/project');
      var reads = 0;
      Future<void> open() => tester.pumpWidget(
        MaterialApp(
          home: ProjectInspectionScreen(
            key: UniqueKey(),
            controller: ProjectInspectionController(
              store: store,
              picker: Picker(),
              inspect: (root) async {
                reads++;
                return result(root);
              },
            ),
          ),
        ),
      );
      await open();
      await tester.tap(find.text('/project'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Open requirements workspace'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Open requirements workspace'));
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text('Imported project workspace'), findsOneWidget);
      expect(find.textContaining('grants no write'), findsOneWidget);
      await tester.tap(find.text('Requirements and tasks'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add requirement'));
      await tester.pumpAndSettle();
      await tester.enterText(find.widgetWithText(TextField, 'Stable ID'), 'R1');
      await tester.enterText(
        find.widgetWithText(TextField, 'Title'),
        'Keep existing source',
      );
      await tester.enterText(
        find.widgetWithText(TextField, 'Acceptance criteria'),
        'No imported files change',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(find.text('R1: Keep existing source'), findsOneWidget);
      await tester.pageBack();
      await tester.pumpAndSettle();
      await tester.pageBack();
      await tester.pumpAndSettle();
      await open();
      await tester.pumpAndSettle();
      await tester.tap(find.text('/project'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Open requirements workspace'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Open requirements workspace'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Requirements and tasks'));
      await tester.pumpAndSettle();
      expect(find.text('R1: Keep existing source'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('saved folder can be reopened after screen recreation', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = InspectedFolderStore(
      PreferenceRecords(await SharedPreferences.getInstance()),
    );
    Future<void> open() => tester.pumpWidget(
      MaterialApp(
        home: ProjectInspectionScreen(
          key: UniqueKey(),
          controller: ProjectInspectionController(
            store: store,
            picker: Picker(),
            inspect: (root) async => result(root),
          ),
        ),
      ),
    );
    await open();
    await tester.tap(find.text('Choose Flutter folder'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Save folder reference'));
    await tester.tap(find.text('Save folder reference'));
    await tester.pumpAndSettle();
    expect(find.text('Saved folders'), findsOneWidget);
    await open();
    await tester.pumpAndSettle();
    expect(find.text('Package: sample'), findsNothing);
    await tester.tap(find.text('/project'));
    await tester.pumpAndSettle();
    expect(find.text('Package: sample'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('narrow screen selects folder and displays limitations', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: ProjectInspectionScreen(
          controller: ProjectInspectionController(
            picker: Picker(),
            inspect: (path) async => result(path),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Choose Flutter folder'));
    await tester.pumpAndSettle();
    expect(find.text('Package: sample'), findsOneWidget);
    expect(find.text('Declared Dart SDK: ^3.9.0'), findsOneWidget);
    expect(find.text('Included runners: web'), findsOneWidget);
    expect(find.text(ProjectInspection.limitations.first), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
