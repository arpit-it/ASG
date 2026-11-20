// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:asg/controllers/project_instruction_controller.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/views/project_instruction_panel.dart';
import 'package:asg/models/project_inspection.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/controllers/imported_plan_controller.dart';
import 'package:asg/views/imported_plan_screen.dart';
import 'package:asg/controllers/imported_advisory_controller.dart';
import 'package:asg/services/imported_advisory_store.dart';
import 'package:asg/views/imported_advisory_screen.dart';

import 'imported_advisory_test.dart' show AdvisoryProvider;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'project_instruction_controller_test.dart'
    show InstructionHost, InstructionRecords, instructionRecords;

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
  testWidgets(
    'record replacement cannot reattach a disposed injected controller',
    (tester) async {
      final first = await instructionRecords(),
          next = await instructionRecords();
      await RuntimeSetupStore(next)
          .save(const RuntimeSetup(python: '/fresh/python'));
      final host = InstructionHost();
      final controller = ProjectInstructionController(
        root: '/selected',
        setupStore: RuntimeSetupStore(first),
        host: host,
      );
      Widget app(InstructionRecords records) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ProjectInstructionPanel(
              root: '/selected',
              records: records,
              controller: controller,
            ),
          ),
        ),
      );
      await tester.pumpWidget(app(first));
      await tester.tap(find.text('Review selected documents'));
      await tester.pumpAndSettle();
      await tester.pumpWidget(app(next));
      await tester.pump();
      expect(controller.isDisposed, true);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Read selected files'));
      await tester.pumpAndSettle();
      expect(host.reads, 0);
      final action = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Review selected documents'),
      );
      if (action.onPressed != null) {
        await tester.tap(find.text('Review selected documents'));
        await tester.pumpAndSettle();
        expect(find.text('Existing Python: /fresh/python'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
      } else {
        expect(
          find.textContaining('This host is unavailable.'),
          findsOneWidget,
        );
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'captured documents need explicit local-save disclosure before manual plan persistence',
    (tester) async {
      final records = await instructionRecords(), host = InstructionHost();
      await InspectedFolderStore(records).save('/selected');
      final inspection = ProjectInspection(
        root: '/selected',
        packageName: 'fixture',
        dartSdk: '^3.0.0',
        runners: ['web'],
      );
      final c = ProjectInstructionController(
        root: '/selected',
        setupStore: RuntimeSetupStore(records),
        host: host,
      );
      ImportedPlanController? plan;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: SingleChildScrollView(
                child: ProjectInstructionPanel(
                  root: '/selected',
                  records: records,
                  controller: c,
                  inspection: inspection,
                  onPlan: (captured) {
                    plan = ImportedPlanController(
                      '/selected',
                      ImportedPlanStore(records, capturedDocuments: captured),
                      inspection: inspection,
                    );
                    Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => ImportedPlanScreen(controller: plan!),
                      ),
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      );
      final planAction = find.widgetWithText(
        OutlinedButton,
        'Plan with captured documents',
      );
      expect(tester.widget<OutlinedButton>(planAction).onPressed, isNull);
      await tester.tap(find.text('Review selected documents'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read selected files'));
      await tester.pumpAndSettle();
      final before = records.writes;
      await tester.tap(planAction);
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Saving a draft stores the captured document text'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(plan, isNull);
      expect(records.writes, before);
      await tester.tap(planAction);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open manual plan'));
      await tester.pumpAndSettle();
      expect(find.text('Imported project plan'), findsOneWidget);
      expect(plan!.capturedDocuments, isNotNull);
      expect(records.writes, before);
      await tester.scrollUntilVisible(
        find.byType(TextField),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(
        find.byType(TextField),
        'Review these captured documents',
      );
      await tester.ensureVisible(find.text('Save draft'));
      await tester.tap(find.text('Save draft'));
      await tester.pumpAndSettle();
      expect(plan!.error, isNull);
      expect(plan!.plan!.context, plan!.capturedDocuments!.recordJson);
      await tester.scrollUntilVisible(
        find.text('Approve saved plan'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Approve saved plan'));
      await tester.pumpAndSettle();
      expect(plan!.approved, true);
      expect(host.reads, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'changed requirements during planning confirmation prevent navigation and writes',
    (tester) async {
      final records = await instructionRecords(), host = InstructionHost();
      await InspectedFolderStore(records).save('/selected');
      final inspection = ProjectInspection(
        root: '/selected',
        packageName: 'fixture',
        dartSdk: '^3.0.0',
        runners: ['web'],
      );
      final c = ProjectInstructionController(
        root: '/selected',
        setupStore: RuntimeSetupStore(records),
        host: host,
      );
      var admitted = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ProjectInstructionPanel(
                root: '/selected',
                records: records,
                controller: c,
                inspection: inspection,
                onPlan: (_) => admitted++,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Review selected documents'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read selected files'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.widgetWithText(OutlinedButton, 'Plan with captured documents'),
      );
      await tester.pumpAndSettle();
      final store = RequirementsStore(records),
          id = InspectedFolderStore.workspaceId('/selected');
      await store.save(id, store.load(id), RequirementsBoard());
      final writes = records.writes;
      await tester.tap(find.text('Open manual plan'));
      await tester.pumpAndSettle();
      expect(admitted, 0);
      expect(records.writes, writes);
      expect(c.error, contains('changed'));
      expect(c.findings, isNotNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'captured-plan disclosure remains scrollable at320pixels and enlarged text',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = await instructionRecords(), host = InstructionHost();
      await InspectedFolderStore(records).save('/selected');
      final inspection = ProjectInspection(
        root: '/selected',
        packageName: 'fixture',
        dartSdk: '^3.0.0',
        runners: ['web'],
      );
      final c = ProjectInstructionController(
        root: '/selected',
        setupStore: RuntimeSetupStore(records),
        host: host,
      );
      var admitted = 0;
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
                inspection: inspection,
                onPlan: (_) => admitted++,
              ),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('Review selected documents'));
      await tester.tap(find.text('Review selected documents'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read selected files'));
      await tester.pumpAndSettle();
      final action = find.widgetWithText(
        OutlinedButton,
        'Plan with captured documents',
      );
      await tester.ensureVisible(action);
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(find.text('Open manual plan'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(admitted, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
    },
  );
  testWidgets(
    'document advisory entry still requires separate sharing consent before provider dispatch',
    (tester) async {
      final records = await instructionRecords(),
          host = InstructionHost(),
          provider = AdvisoryProvider();
      await InspectedFolderStore(records).save('/selected');
      final inspection = ProjectInspection(
        root: '/selected',
        packageName: 'fixture',
        dartSdk: '^3.0.0',
        runners: ['web'],
      );
      final owner = ProjectInstructionController(
        root: '/selected',
        setupStore: RuntimeSetupStore(records),
        host: host,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: SingleChildScrollView(
                child: ProjectInstructionPanel(
                  root: '/selected',
                  records: records,
                  controller: owner,
                  inspection: inspection,
                  onAdvisory: (captured) => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => ImportedAdvisoryScreen(
                        controller: ImportedAdvisoryController(
                          inspection: inspection,
                          context: captured,
                          store: ImportedAdvisoryStore(records),
                          createProvider: (_) => provider,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      final action = find.widgetWithText(
        OutlinedButton,
        'Ask about captured documents',
      );
      expect(tester.widget<OutlinedButton>(action).onPressed, isNull);
      await tester.tap(find.text('Review selected documents'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Read selected files'));
      await tester.pumpAndSettle();
      final writes = records.writes;
      await tester.tap(action);
      await tester.pumpAndSettle();
      expect(provider.calls, 0);
      expect(records.writes, writes);
      await tester.scrollUntilVisible(
        find.byType(TextField),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(find.byType(TextField), 'Explain only');
      await tester.ensureVisible(find.text('Review and send question'));
      await tester.tap(find.text('Review and send question'));
      await tester.pumpAndSettle();
      expect(
        find.text('Send captured context to local model?'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(provider.calls, 0);
      expect(records.writes, writes);
      expect(host.reads, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expect(tester.takeException(), isNull);
    },
  );
}
