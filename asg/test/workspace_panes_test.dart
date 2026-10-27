// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/controllers/workspace_layout_controller.dart';
import 'package:asg/controllers/app_workspace_controller.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/views/project_workspace.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'interaction_persistence_test.dart' show project, initial;

import 'package:asg/views/workspace_panes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('layout bounds, restore and mobile selection preserve split', () {
    final controller = WorkspaceLayoutController();
    addTearDown(controller.dispose);
    controller.resize(-1, .3);
    expect(controller.fraction, .3);
    controller.resize(2, .3);
    expect(controller.fraction, .7);
    controller.resize(double.nan, .3);
    expect(controller.fraction, .7);
    controller.toggle(0);
    expect(controller.collapsed, 0);
    controller.select(1);
    controller.toggle(0);
    expect(controller.collapsed, isNull);
    expect(controller.fraction, .7);
    expect(controller.mobilePane, 1);
    controller.toggle(1);
    controller.toggle(0);
    expect(controller.collapsed, 0);
  });

  testWidgets('pointer and keyboard resize remain bounded', (tester) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WorkspacePanes(
            chat: ColoredBox(key: ValueKey('chat'), color: Colors.red),
            preview: ColoredBox(key: ValueKey('preview'), color: Colors.blue),
          ),
        ),
      ),
    );
    final chat = find.byKey(const ValueKey('chat'));
    final before = tester.getSize(chat).width;
    await tester.drag(
      find.byKey(const ValueKey('workspaceDivider')),
      const Offset(100, 0),
    );
    await tester.pump();
    expect(tester.getSize(chat).width, greaterThan(before));
    await tester.drag(
      find.byKey(const ValueKey('workspaceDivider')),
      const Offset(-2000, 0),
    );
    await tester.pump();
    expect(tester.getSize(chat).width, closeTo(360, .01));
    // Slider's focusable keyboard action is the accessible resize alternative.
    await tester.tap(find.byKey(const ValueKey('workspaceResize')));
    await tester.pump();
    final keyboardBefore = tester.getSize(chat).width;
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
    await tester.pump();
    expect(tester.getSize(chat).width, greaterThan(keyboardBefore));
    expect(tester.takeException(), isNull);
  });

  testWidgets('collapse, restore and responsive tabs retain child state', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1200, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: WorkspacePanes(
            chat: TextField(key: ValueKey('draft')),
            preview: _Counter(),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const ValueKey('draft')),
      'Unsaved instruction',
    );
    await tester.tap(find.text('Count 0'));
    await tester.pump();
    final element = tester.element(find.text('Count 1'));
    await tester.tap(find.text('Collapse preview'));
    await tester.pump();
    expect(find.text('Count 1'), findsNothing);
    await tester.tap(find.text('Restore preview'));
    await tester.pump();
    expect(tester.element(find.text('Count 1')), same(element));
    await tester.tap(find.text('Collapse chat'));
    await tester.pump();
    expect(
      tester
          .widget<EditableText>(find.byType(EditableText, skipOffstage: false))
          .focusNode
          .canRequestFocus,
      isFalse,
    );
    await tester.tap(find.text('Restore chat'));
    await tester.pump();
    expect(find.text('Unsaved instruction'), findsOneWidget);
    tester.view.physicalSize = const Size(360, 800);
    await tester.pump();
    await tester.tap(find.text('Preview'));
    await tester.pump();
    expect(find.text('Count 1'), findsOneWidget);
    await tester.tap(find.text('Chat'));
    await tester.pump();
    expect(find.text('Unsaved instruction'), findsOneWidget);
    tester.view.physicalSize = const Size(1200, 800);
    await tester.pump();
    expect(tester.element(find.text('Count 1')), same(element));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'real workspace retains draft and prototype across layout changes',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      SharedPreferences.setMockInitialValues({});
      final store = ApplicationStore(
        PreferenceRecords(await SharedPreferences.getInstance()),
      );
      await store.save(project.id, const ApplicationSnapshot(initial, [], 7));
      final controller = AppWorkspaceController(
        project,
        openStore: () async => store,
      );
      final scale = ValueNotifier<double>(1);
      addTearDown(scale.dispose);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => ValueListenableBuilder<double>(
            valueListenable: scale,
            builder: (context, value, _) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(value)),
              child: child!,
            ),
          ),
          home: ProjectWorkspace(project: project, controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      final draft = find.widgetWithText(
        TextField,
        'For example: add a counter and change the theme to green',
      );
      await tester.enterText(draft, 'Keep this draft');
      await tester.tap(find.byTooltip('Increase Count'));
      await tester.pumpAndSettle();
      expect(controller.definition!.elements.first.value, '1');
      await tester.tap(find.text('Collapse preview'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore preview'));
      await tester.pumpAndSettle();
      expect(find.text('Keep this draft'), findsOneWidget);
      tester.view.physicalSize = const Size(360, 900);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Preview'));
      await tester.pumpAndSettle();
      expect(controller.definition!.elements.first.value, '1');
      scale.value = 2;
      await tester.pumpAndSettle();
      await tester.tap(find.text('Chat').last);
      await tester.pumpAndSettle();
      expect(find.text('Keep this draft'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );

  testWidgets('enlarged text uses narrow tabs without overflow', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: const Scaffold(
            body: WorkspacePanes(
              chat: Text('Conversation'),
              preview: Text('Prototype'),
            ),
          ),
        ),
      ),
    );
    expect(find.text('Collapse chat'), findsNothing);
    expect(find.text('Chat'), findsOneWidget);
    await tester.tap(find.text('Preview'));
    await tester.pump();
    expect(find.text('Prototype'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _Counter extends StatefulWidget {
  const _Counter();
  @override
  State<_Counter> createState() => _CounterState();
}

class _CounterState extends State<_Counter> {
  int count = 0;
  @override
  Widget build(BuildContext context) => Center(
    child: TextButton(
      onPressed: () => setState(() => count++),
      child: Text('Count $count'),
    ),
  );
}
