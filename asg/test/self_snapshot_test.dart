// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/models/self_snapshot_operation.dart';
import 'package:asg/controllers/self_snapshot_controller.dart';
import 'package:asg/models/generation_command_result.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/views/self_snapshot_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FixturePicker extends FolderPicker {
  final folders = ['/source', '/destination'].iterator;

  @override
  Future<String?> pick() async => folders.moveNext() ? folders.current : null;
}

void main() {
  final commitId = 'a' * 40;

  testWidgets(
    'prepares only on explicit action and ignores a late Stop result',
    (tester) async {
      final result = Completer<String>();
      var calls = 0;
      final controller = SelfSnapshotController(
        prepare:
            ({
              required source,
              required destination,
              required commit,
              required python,
              required stop,
              required stopped,
            }) {
              calls++;
              expect(
                (source, destination, commit, python),
                ('/source', '/destination', commitId, '/python'),
              );
              return result.future;
            },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SelfSnapshotScreen(
            controller: controller,
            picker: FixturePicker(),
          ),
        ),
      );
      await tester.tap(find.text('Choose trusted checkout'));
      await tester.pump();
      await tester.tap(find.text('Choose snapshot destination'));
      await tester.pump();
      await tester.enterText(find.byType(TextField).at(0), commitId);
      await tester.enterText(find.byType(TextField).at(1), '/python');
      expect(calls, 0);
      await tester.tap(find.text('Prepare source snapshot'));
      await tester.pump();
      expect(calls, 1);
      await tester.tap(find.text('Stop'));
      await tester.pump();
      result.complete('/ready');
      await tester.pump();
      expect(find.textContaining('Preparation stopped'), findsOneWidget);
      expect(find.textContaining('Snapshot ready'), findsNothing);
    },
  );

  test('invalid commit is rejected before starting a process', () async {
    final controller = SelfSnapshotController();
    addTearDown(controller.dispose);
    await controller.prepare(
      source: '/source',
      destination: '/destination',
      commit: 'HEAD',
      python: '/python',
    );
    expect(controller.busy, isFalse);
    expect(controller.status, contains('full commit ID'));
  });
  testWidgets('inspection uses the selected destination without preparation', (
    tester,
  ) async {
    final pending = Completer<List<String>>();
    final picker = FixturePicker()..folders.moveNext();
    final controller = SelfSnapshotController(
      inspect: (destination) {
        expect(destination, '/destination');
        return pending.future;
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        home: SelfSnapshotScreen(controller: controller, picker: picker),
      ),
    );
    await tester.tap(find.text('Choose snapshot destination'));
    await tester.pump();
    await tester.ensureVisible(find.text('Find incomplete snapshots'));
    await tester.tap(find.text('Find incomplete snapshots'));
    await tester.pump();
    expect(find.text('Inspecting destination…'), findsOneWidget);
    expect(find.text('Stop'), findsNothing);
    pending.complete(['/destination/asg-self-candidate-a1b2c3d4/incomplete']);
    await tester.pump();
    expect(
      find.textContaining('Possible incomplete snapshot folders'),
      findsOneWidget,
    );
    await tester.tap(find.text('Choose snapshot destination'));
    await tester.pump();
    expect(
      find.textContaining('Possible incomplete snapshot folders'),
      findsOneWidget,
    );
  });
  test('checks require approval and Stop suppresses analysis', () async {
    final result = Completer<GenerationCommandResult>();
    final calls = <bool>[];
    final controller = SelfSnapshotController(
      check:
          ({
            required snapshot,
            required sdk,
            required python,
            required operation,
            required stop,
            required stopped,
          }) {
            expect((snapshot, sdk, python), ('/snapshot', '/sdk', '/python'));
            calls.add(operation == SelfSnapshotOperation.analyze);
            return result.future;
          },
    );
    addTearDown(controller.dispose);
    Future<void> run(bool approved) => controller.check(
      approved: approved,
      snapshot: '/snapshot',
      sdk: '/sdk',
      python: '/python',
    );
    await run(false);
    expect(calls, isEmpty);
    final operation = run(true);
    expect(calls, [false]);
    controller.stop();
    result.complete(const GenerationCommandResult(exitCode: 0, output: ''));
    await operation;
    expect(calls, [false]);
    expect(controller.status, 'Snapshot checks stopped.');
  });

  test(
    'analyze runs only after successful resolve and reports actual exit',
    () async {
      final calls = <bool>[];
      final controller = SelfSnapshotController(
        check:
            ({
              required snapshot,
              required sdk,
              required python,
              required operation,
              required stop,
              required stopped,
            }) async {
              calls.add(operation == SelfSnapshotOperation.analyze);
              return GenerationCommandResult(
                exitCode: operation == SelfSnapshotOperation.analyze ? 1 : 0,
                output: '',
              );
            },
      );
      addTearDown(controller.dispose);
      await controller.check(
        approved: true,
        snapshot: '/snapshot',
        sdk: '/sdk',
        python: '/python',
      );
      expect(calls, [false, true]);
      expect(
        controller.status,
        'Offline dependency resolution passed.\nAnalysis failed (exit 1).',
      );
    },
  );
  testWidgets(
    'review names the selected snapshot and Cancel starts no checks',
    (tester) async {
      final calls = <SelfSnapshotOperation>[];
      final controller = SelfSnapshotController(
        check:
            ({
              required snapshot,
              required sdk,
              required python,
              required operation,
              required stop,
              required stopped,
            }) async {
              expect((snapshot, sdk, python), ('/source', '/sdk', '/python'));
              calls.add(operation);
              return const GenerationCommandResult(exitCode: 0, output: '');
            },
      );
      await tester.pumpWidget(
        MaterialApp(
          home: SelfSnapshotScreen(
            controller: controller,
            picker: FixturePicker(),
          ),
        ),
      );
      await tester.enterText(find.byType(TextField).at(1), '/python');
      final pick = find.text('Choose prepared snapshot for checks');
      await tester.ensureVisible(pick);
      await tester.tap(pick);
      await tester.pumpAndSettle();
      final field = find.widgetWithText(TextField, 'Flutter SDK folder');
      await tester.ensureVisible(field);
      await tester.enterText(field, '/sdk');
      final review = find.text('Review offline checks');
      await tester.ensureVisible(review);
      await tester.tap(review);
      await tester.pumpAndSettle();
      expect(find.textContaining('Flutter SDK: /sdk'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      await tester.tap(review);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Approve and run'));
      await tester.pumpAndSettle();
      expect(calls, [
        SelfSnapshotOperation.resolve,
        SelfSnapshotOperation.analyze,
      ]);
      expect(controller.status, contains('Analysis passed'));
      calls.clear();
      final build = find.widgetWithText(
        OutlinedButton,
        'Review offline web build',
      );
      await tester.ensureVisible(build);
      await tester.pumpAndSettle();
      await tester.tap(build);
      await tester.pumpAndSettle();
      expect(find.text('Approve offline web build?'), findsOneWidget);
      expect(calls, isEmpty);
      await tester.tap(find.text('Approve and run'));
      await tester.pumpAndSettle();
      expect(calls, [
        SelfSnapshotOperation.resolve,
        SelfSnapshotOperation.build,
      ]);
      expect(
        controller.status,
        contains('Web artifacts at /source/asg/build/web'),
      );
    },
  );
}
