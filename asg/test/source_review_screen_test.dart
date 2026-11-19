// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/session_proposal_request.dart';
import 'package:asg/views/source_request_history.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'session_proposal_request_test.dart' show requestMetadata;

void main() {
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
