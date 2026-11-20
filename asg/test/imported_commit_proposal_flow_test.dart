// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:asg/controllers/imported_plan_controller.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/views/imported_plan_screen.dart';
import 'package:asg/views/imported_project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_plan_test.dart' show finding;
import 'imported_commit_proposal_controller_test.dart' as fixture;
import 'imported_commit_proposal_record_test.dart' show capturedCommitPlan;

void main() {
  testWidgets(
    'workspace opens separate committed history without source reads or current approval',
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
      final button = find.text('Open saved committed-source comparison');
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(find.text('Saved committed-source comparison'), findsOneWidget);
      expect(
        find.text('No saved committed-source comparison for this folder.'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsNothing);
      expect(records.values, isEmpty);
      expect(records.updatesSeen, everyElement(isEmpty));
    },
  );
  testWidgets(
    'only exact current approved committed plan enables proposal entry',
    (tester) async {
      final records = await fixture.proposalRecords();
      final captured = capturedCommitPlan();
      final controller = ImportedPlanController(
        '/project',
        ImportedPlanStore(records, capturedCommit: captured),
        inspection: finding(),
      );
      var entries = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ImportedPlanScreen(
            controller: controller,
            onCommittedProposal: () {
              entries++;
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.text('Review committed-source change');
      await tester.scrollUntilVisible(
        button,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(entries, 1);
      expect(controller.canReviewCommittedProposal, true);
      await tester.pumpWidget(const SizedBox());
      final ordinary = ImportedPlanController(
        '/project',
        ImportedPlanStore(records),
        inspection: finding(),
      );
      await ordinary.load();
      expect(ordinary.canReviewCommittedProposal, false);
      ordinary.dispose();
      expect(records.updatesSeen, everyElement(isEmpty));
    },
  );
}
