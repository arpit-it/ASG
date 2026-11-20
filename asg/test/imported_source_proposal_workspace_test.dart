// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:asg/views/imported_project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_source_proposal_controller_test.dart' as fixture;
import 'imported_plan_test.dart' show finding;
import 'imported_source_baseline_controller_test.dart' show baselineRecords;
import 'imported_source_baseline_test.dart' show baselineSaved;

void main() {
  testWidgets(
    'workspace opens history with no source capture or reviewed plan',
    (tester) async {
      final records = await fixture.proposalRecords();
      records.values.clear();
      await tester.pumpWidget(
        MaterialApp(
          home: ImportedProjectWorkspace(
            inspection: finding(),
            records: records,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Open saved source comparison'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open saved source comparison'));
      await tester.pumpAndSettle();
      expect(find.text('Saved source comparison'), findsOneWidget);
      expect(
        find.text('No saved source comparison for this folder.'),
        findsOneWidget,
      );
      expect(find.text('Preview read-only diff'), findsNothing);
      expect(records.values, isEmpty);
      expect(records.updatesSeen, everyElement(isEmpty));
    },
  );
  testWidgets(
    'saved history offers baseline recheck without automatically reading files',
    (tester) async {
      final saved = baselineSaved(),
          records = await baselineRecords(baselineSaved());
      final before = Map<String, String>.of(records.values);
      await tester.pumpWidget(
        MaterialApp(
          home: ImportedProjectWorkspace(
            inspection: finding(),
            records: records,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Open saved source comparison'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open saved source comparison'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Recheck captured files'),
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Recheck captured files'));
      await tester.pumpAndSettle();
      expect(find.text('Recheck captured source baseline'), findsOneWidget);
      expect(find.text('Read captured files again?'), findsNothing);
      expect(records.values, before);
      expect(records.updatesSeen, everyElement(isEmpty));
      expect(saved.sourceVerified, false);
    },
  );
}
