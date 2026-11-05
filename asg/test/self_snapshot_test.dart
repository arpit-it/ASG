// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/controllers/self_snapshot_controller.dart';
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
}
