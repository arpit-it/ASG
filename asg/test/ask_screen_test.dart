// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/ask_controller.dart';
import 'package:asg/models/project.dart';
import 'package:asg/services/ask_store.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/ask_screen.dart';
import 'package:asg/views/studio_app.dart';
import 'package:asg/views/studio_home.dart';

import 'ask_controller_test.dart' show AskRecords, AskProvider;

void main() {
  testWidgets('landing Ask opens without creating a project', (tester) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = AskRecords();
    await tester.pumpWidget(StudioApp(store: StudioStore(records)));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Ask engineering questions'));
    await tester.pumpAndSettle();
    expect(
      find.text('Engineering questions · no project required'),
      findsOneWidget,
    );
    expect(StudioStore(records).load(), isEmpty);
    expect(records.writes, 0);
  });
  testWidgets(
    'selected narrow workspace reaches Ask and scrolls all toolbar actions',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = AskRecords();
      final store = StudioStore(records);
      const project = StudioProject(
        id: 'p',
        name: 'Demo',
        description: 'test',
        type: 'Flutter',
        platforms: ['Web'],
        location: '',
      );
      await store.save([project]);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: StudioHome(store: store, projects: const [project]),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(
        find.byTooltip('Ask engineering questions').hitTestable(),
        findsOneWidget,
      );
      final toolbar = find.byKey(const ValueKey('studio-toolbar-actions'));
      await tester.drag(toolbar, const Offset(-350, 0));
      await tester.pumpAndSettle();
      expect(find.byTooltip('New project').hitTestable(), findsOneWidget);
      // Focus traversal calls showOnScreen for offscreen toolbar controls.
      await tester.ensureVisible(find.byTooltip('Ask engineering questions'));
      await tester.pumpAndSettle();
      expect(
        find.byTooltip('Ask engineering questions').hitTestable(),
        findsOneWidget,
      );
      await tester.tap(find.byTooltip('Ask engineering questions'));
      await tester.pumpAndSettle();
      expect(
        find.text('Engineering questions · no project required'),
        findsOneWidget,
      );
      expect(store.load().single.id, project.id);
      expect(AskStore(records).load(), isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'narrow scaled keyboard send, streamed code, save recovery and new context',
    (tester) async {
      tester.view.physicalSize = const Size(320, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = AskRecords()..failWrite = 2;
      final provider = AskProvider();
      final controller = AskController(
        AskStore(records),
        createProvider: (_) => provider,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(
              textScaler: const TextScaler.linear(1.5),
              viewInsets: const EdgeInsets.only(bottom: 160),
            ),
            child: child!,
          ),
          home: AskScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(TextField),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), 'Explain this code');
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();
      expect(controller.busy, isTrue);
      provider.stream.add('Explanation\n```dart\nfinal x = 1;\n```');
      await tester.pump();
      expect(controller.draft, contains('final x'));
      await provider.stream.close();
      await tester.pumpAndSettle();
      expect(controller.unsavedAnswer, isNotNull);
      await tester.scrollUntilVisible(
        find.text('Retry saving'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      records.failWrite = null;
      await tester.tap(find.text('Retry saving'));
      await tester.pumpAndSettle();
      expect(controller.unsavedAnswer, isNull);
      expect(provider.prompts.length, 1);
      expect(controller.messages.last.content, contains('final x'));
      await tester.tap(find.byTooltip('New Ask conversation'));
      await tester.pumpAndSettle();
      expect(controller.messages, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
}
