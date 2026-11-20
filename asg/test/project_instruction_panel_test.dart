// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:asg/controllers/project_instruction_controller.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/views/project_instruction_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'project_instruction_controller_test.dart'
    show InstructionHost, instructionRecords;

void main() {
  testWidgets(
    'narrow enlarged confirmation cancels then reads plain attributed text',
    (tester) async {
      tester.view.resetPhysicalSize();
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = await instructionRecords(), host = InstructionHost();
      final c = ProjectInstructionController(
        root: '/selected',
        setupStore: RuntimeSetupStore(records),
        host: host,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProjectInstructionPanel(
                root: '/selected',
                records: records,
                controller: c,
              ),
            ),
          ),
        ),
      );
      expect(host.reads, 0);
      await tester.ensureVisible(find.text('Review selected documents'));
      await tester.tap(find.text('Review selected documents'));
      await tester.pumpAndSettle();
      expect(find.text('Confirm document read'), findsOneWidget);
      expect(find.text('Existing Python: /trusted/python'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(host.reads, 0);
      await tester.ensureVisible(find.text('Review selected documents'));
      await tester.tap(find.text('Review selected documents'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read selected files'));
      await tester.pumpAndSettle();
      expect(host.reads, 1);
      expect(
        find.text('Untrusted [AGENTS.md](file://private)\n'),
        findsOneWidget,
      );
      expect(records.writes, 0);
      expect(tester.takeException(), isNull);
      host.onRead = (_) async => throw StateError('private-sentinel');
      await tester.ensureVisible(find.text('Review selected documents'));
      await tester.tap(find.text('Review selected documents'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read selected files'));
      await tester.pumpAndSettle();
      expect(find.text('Previous document findings — stale'), findsOneWidget);
      expect(find.textContaining('private-sentinel'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(host.disposals, 1);
    },
  );
  testWidgets('replaced workspace invalidates consent from the old dialog', (
    tester,
  ) async {
    final records = await instructionRecords(),
        oldHost = InstructionHost(),
        newHost = InstructionHost();
    final old = ProjectInstructionController(
      root: '/selected',
      setupStore: RuntimeSetupStore(records),
      host: oldHost,
    );
    final next = ProjectInstructionController(
      root: '/other',
      setupStore: RuntimeSetupStore(records),
      host: newHost,
    );
    Widget app(String root, ProjectInstructionController c) => MaterialApp(
      home: Scaffold(
        body: SingleChildScrollView(
          child: ProjectInstructionPanel(
            root: root,
            records: records,
            controller: c,
          ),
        ),
      ),
    );
    await tester.pumpWidget(app('/selected', old));
    await tester.tap(find.text('Review selected documents'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app('/other', next));
    await tester.pump();
    await tester.tap(find.text('Read selected files'));
    await tester.pumpAndSettle();
    expect(old.isDisposed, true);
    expect(oldHost.reads, 0);
    expect(newHost.reads, 0);
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
