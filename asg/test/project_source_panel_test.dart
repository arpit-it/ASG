// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:asg/controllers/project_source_controller.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/views/project_source_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'project_source_controller_test.dart' show SourceHost, sourceRecords;

void main() {
  testWidgets(
    'explicit confirmation captures literal source and selection changes mark it stale',
    (tester) async {
      final records = await sourceRecords();
      final host = SourceHost();
      final controller = ProjectSourceController(
        root: '/selected',
        setupStore: RuntimeSetupStore(records),
        host: host,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProjectSourcePanel(
                root: '/selected',
                records: records,
                controller: controller,
              ),
            ),
          ),
        ),
      );
      expect(host.reads, 0);
      await tester.tap(find.text('Review selected source'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm source read'), findsOneWidget);
      expect(find.text('Existing Python: /trusted/python'), findsOneWidget);
      expect(host.reads, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(host.reads, 0);
      await tester.tap(find.text('Review selected source'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read selected source'));
      await tester.pumpAndSettle();
      expect(host.reads, 1);
      expect(find.text('Captured source files'), findsOneWidget);
      expect(
        find.text('Untrusted [lib/main.dart](file://private)\n'),
        findsOneWidget,
      );
      expect(records.writes, 0);
      await tester.enterText(find.byType(TextField), 'test/other.dart');
      await tester.pump();
      expect(find.text('Previous source capture — stale'), findsOneWidget);
    },
  );

  testWidgets('literal invalid paths refuse before consent or dispatch', (
    tester,
  ) async {
    final records = await sourceRecords();
    final host = SourceHost();
    final controller = ProjectSourceController(
      root: '/selected',
      setupStore: RuntimeSetupStore(records),
      host: host,
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ProjectSourcePanel(
            root: '/selected',
            records: records,
            controller: controller,
          ),
        ),
      ),
    );
    await tester.enterText(find.byType(TextField), ' lib/main.dart');
    await tester.tap(find.text('Review selected source'));
    await tester.pumpAndSettle();
    expect(find.text('Confirm source read'), findsNothing);
    expect(controller.error, isNotNull);
    expect(host.reads, 0);
  });

  testWidgets('replaced workspace drops old confirmation and disposes owner', (
    tester,
  ) async {
    final records = await sourceRecords();
    final host = SourceHost();
    final controller = ProjectSourceController(
      root: '/selected',
      setupStore: RuntimeSetupStore(records),
      host: host,
    );
    Widget app(String root) => MaterialApp(
      home: Scaffold(
        body: ProjectSourcePanel(
          root: root,
          records: records,
          controller: controller,
        ),
      ),
    );
    await tester.pumpWidget(app('/selected'));
    await tester.tap(find.text('Review selected source'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app('/replaced'));
    await tester.tap(find.text('Read selected source'));
    await tester.pumpAndSettle();
    expect(controller.isDisposed, isTrue);
    expect(host.reads, 0);
  });

  testWidgets('Stop retains prior capture while the owned read settles', (
    tester,
  ) async {
    final records = await sourceRecords();
    final host = SourceHost();
    final controller = ProjectSourceController(
      root: '/selected',
      setupStore: RuntimeSetupStore(records),
      host: host,
    );
    await controller.read(['lib/main.dart'], confirm: (_) async => true);
    final pending = Completer<Never>();
    host.onRead = (_) => pending.future;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProjectSourcePanel(
              root: '/selected',
              records: records,
              controller: controller,
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Review selected source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Read selected source'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.text('Stop source read'));
    await tester.pump();
    expect(controller.stale, isTrue);
    expect(find.text('Previous source capture — stale'), findsOneWidget);
    pending.completeError(StateError('private failure'));
    await tester.pumpAndSettle();
    expect(find.textContaining('private failure'), findsNothing);
  });
  testWidgets('capture remains scrollable at narrow width and large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = await sourceRecords();
    final host = SourceHost();
    final controller = ProjectSourceController(
      root: '/selected',
      setupStore: RuntimeSetupStore(records),
      host: host,
    );
    await controller.read(['lib/main.dart'], confirm: (_) async => true);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProjectSourcePanel(
              root: '/selected',
              records: records,
              controller: controller,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Captured source files'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Captured source files'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
