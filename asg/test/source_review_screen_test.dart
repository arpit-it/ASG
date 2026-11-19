// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/session_proposal_request.dart';
import 'package:asg/controllers/source_review_controller.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/views/source_review_screen.dart';

import 'approved_source_proposer_test.dart' show seed;
import 'planning_conversation_test.dart' show project;
import 'source_candidate_controller_test.dart' show AtomicRecords;

import 'package:asg/views/source_request_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_proposal_request_test.dart' show requestMetadata;
import '../tools/fixtures/candidate_reopen.dart'
    show selectedRepairFixtureHome, retainedRepairCopyFixtureHome;

class RetainedCopyReviewProjection extends SourceReviewController {
  RetainedCopyReviewProjection(AtomicRecords records)
    : super(
        project: project,
        records: records,
        generated: GeneratedProject(
          directory: '/working/retained',
          sdk: '',
          python: '',
          sources: const {},
        ),
      );
  @override
  GeneratedProject get candidate => GeneratedProject(
    directory: '/candidate/previous-failed',
    sdk: '',
    python: '',
    sources: const {},
  );
  @override
  String get retainedRepairCopyDirectory => '/candidate/copied-after-refusal';
}

void main() {
  testWidgets('retained repair copy browser fixture initializes read-only', (
    tester,
  ) async {
    final home = await retainedRepairCopyFixtureHome();
    await tester.pumpWidget(MaterialApp(home: home));
    await tester.pumpAndSettle();
    expect(find.text('Retained repair copy UI fixture'), findsOneWidget);
    expect(find.textContaining('Writes: 0'), findsOneWidget);
    expect(find.text('Records unchanged: true'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'narrow enlarged source review separates refused repair copy from old candidate',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = AtomicRecords();
      await seed(records);
      final controller = RetainedCopyReviewProjection(records);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: SourceReviewScreen(controller: controller),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('/working/retained'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('/working/retained'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('/candidate/previous-failed'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('/candidate/previous-failed'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('/candidate/copied-after-refusal'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('/candidate/copied-after-refusal'), findsOneWidget);
      expect(
        find.text('Unverified repair copy retained after preparation stopped'),
        findsOneWidget,
      );
      expect(
        find.textContaining('This copy has no new check results'),
        findsOneWidget,
      );
      expect(find.text('Promote retained copy'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selected repair browser fixture initializes with zero effects', (
    tester,
  ) async {
    final home = await selectedRepairFixtureHome();
    await tester.pumpWidget(MaterialApp(home: home));
    await tester.pumpAndSettle();
    expect(find.text('Selected repair provenance UI fixture'), findsOneWidget);
    expect(find.text('Records unchanged: true'), findsOneWidget);
    expect(find.textContaining('Writes after setup: 0'), findsOneWidget);
    expect(find.textContaining('Providers: 0'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'narrow two-times-text history distinguishes all outcomes and has no replay action',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var reloads = 0;
      final requests = [
        requestMetadata(),
        requestMetadata(number: 2).finish(
          SessionProposalRequestStatus.returnedValidated,
          at: DateTime.utc(2026, 11, 19),
          returnedSha256: {'lib/main.dart': 'e' * 64},
          responseModel: 'Qwen3.8-27B-4bit',
        ),
        requestMetadata(number: 3).finish(
          SessionProposalRequestStatus.failedLocally,
          at: DateTime.utc(2026, 11, 19),
        ),
        requestMetadata(number: 4).finish(
          SessionProposalRequestStatus.cancelledLocally,
          at: DateTime.utc(2026, 11, 19),
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: Scaffold(
            body: SingleChildScrollView(
              child: SourceRequestHistory(
                sessionId: 'session',
                requests: requests,
                error: null,
                onReload: () => reloads++,
              ),
            ),
          ),
        ),
      );
      expect(find.text('Saved initial source requests'), findsOneWidget);
      expect(find.textContaining('Outcome unresolved.'), findsOneWidget);
      expect(
        find.textContaining('Validated proposal returned at that time.'),
        findsOneWidget,
      );
      expect(find.textContaining('Request failed locally.'), findsOneWidget);
      expect(find.textContaining('Request cancelled locally.'), findsOneWidget);
      expect(find.textContaining('Unbound source requests'), findsNothing);
      await tester.ensureVisible(find.text('Reload request history'));
      await tester.tap(find.text('Reload request history'));
      expect(reloads, 1);
      await tester.ensureVisible(find.text('Initial request 2 · Ttest'));
      await tester.tap(find.text('Initial request 2 · Ttest'));
      await tester.pumpAndSettle();
      expect(
        find.textContaining('Returned replacement fingerprint:'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Recorded working fingerprint:'),
        findsOneWidget,
      );
      expect(find.text('Replay request'), findsNothing);
      expect(find.text('Prepare candidate'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'unbound, empty and independently unavailable history have explicit states',
    (tester) async {
      Future<void> show({
        String? id = 'session',
        String? error,
        List<SessionProposalRequest> requests = const [],
      }) => tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SourceRequestHistory(
              sessionId: id,
              requests: requests,
              error: error,
              onReload: () {},
            ),
          ),
        ),
      );
      await show(id: null);
      expect(
        find.textContaining('Unbound source requests are not journaled'),
        findsOneWidget,
      );
      await show();
      expect(find.text('No saved initial source requests.'), findsOneWidget);
      await show(
        error: 'History unavailable. Reload to retry.',
        requests: [requestMetadata()],
      );
      expect(
        find.textContaining('Last observed request history;'),
        findsOneWidget,
      );
      expect(find.text('No saved initial source requests.'), findsNothing);
      expect(
        find.text('History unavailable. Reload to retry.'),
        findsOneWidget,
      );
    },
  );
}
