// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:asg/views/imported_project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_source_proposal_controller_test.dart' as fixture;
import 'imported_plan_test.dart' show finding;

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
}
