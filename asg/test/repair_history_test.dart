import 'dart:convert';

import 'package:asg/controllers/source_review_controller.dart';
import 'package:asg/models/repair_attempt.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/repair_attempt_store.dart';
import 'package:asg/views/source_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'approved_source_proposer_test.dart' show seed, originals, response;
import 'candidate_repair_proposer_test.dart' show boundFailure;
import 'planning_conversation_test.dart' show project;
import 'repair_attempt_store_test.dart' show run;
import 'source_candidate_controller_test.dart' show AtomicRecords;

void main() {
  testWidgets(
    'fresh review shows saved outcomes, exit, output and diff at 320px/200 percent',
    (tester) async {
      final records = AtomicRecords();
      await seed(records);
      final failure = run(records);
      for (final status in [
        RepairAttemptStatus.reserved,
        RepairAttemptStatus.proposed,
        RepairAttemptStatus.failed,
      ]) {
        final store = RepairAttemptStore(records, project.id);
        await store.reserve(failure, () {});
        if (status != RepairAttemptStatus.reserved) {
          await store.finish(
            status,
            proposal: status == RepairAttemptStatus.proposed
                ? SourceEditProposal.parse(
                    jsonDecode(response()),
                    originals: originals,
                  )
                : null,
          );
        }
      }
      final saved = Map.of(records.values);
      final controller = SourceReviewController(
        project: project,
        generated: boundFailure(records),
        records: records,
      );
      expect(controller.repairUsage, {'analyze': 3, 'test': 0, 'build': 0});
      expect(controller.repairHistory.length, 3);
      expect(() => controller.repairHistory.clear(), throwsUnsupportedError);
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: SourceReviewScreen(controller: controller),
        ),
      );
      Future<void> show(Finder finder) async {
        await tester.scrollUntilVisible(
          finder,
          250,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.ensureVisible(finder);
        await tester.pumpAndSettle();
      }

      await show(find.text('analyze: 3/3 requests used'));
      await show(find.text('Model request failed. Budget consumed.'));
      await show(find.textContaining('Proposal saved, unverified.'));
      await tester.ensureVisible(find.text('Repair request 2 · analyze'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Repair request 2 · analyze'));
      await tester.pumpAndSettle();
      await show(find.text('Original analyze exit 65'));
      await show(find.text('Undefined name at lib/main.dart:7'));
      await show(find.text('Line changes'));
      expect(tester.takeException(), isNull);
      expect(records.values, saved);
      await tester.pumpWidget(const SizedBox());
      expect(controller.isDisposed, isTrue);
    },
  );

  test('history distinguishes cancelled and corrupt records and old approvals without writes', () async {
    final records = AtomicRecords();
    await seed(records);
    final store = RepairAttemptStore(records, project.id);
    await store.reserve(run(records), () {});
    await store.finish(RepairAttemptStatus.cancelled);
    final controller = SourceReviewController(
      project: project,
      generated: boundFailure(records),
      records: records,
    );
    addTearDown(controller.dispose);
    expect(
      controller.repairHistory.single.status,
      RepairAttemptStatus.cancelled,
    );
    expect(controller.repairUsage['analyze'], 1);
    await PlanApprovalStore(records)
        .save(project, ConversationStore(records).load(project.id), false);
    controller.refreshApproval();
    expect(controller.repairUsage['analyze'], 0);
    expect(controller.repairHistory.length, 1);
    expect(
      controller.repairUsesCurrentApproval(controller.repairHistory.single),
      isFalse,
    );
    records.values[store.key] = '{}';
    final saved = Map.of(records.values);
    controller.refreshApproval();
    expect(controller.repairHistoryError, contains('unreadable'));
    expect(controller.canRequestRepair, isFalse);
    expect(controller.repairBlockedReason, contains('unreadable'));
    expect(records.values, saved);
  });
}
