// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/selected_repair_request.dart';
import 'package:asg/views/selected_repair_request_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'selected_repair_request_test.dart' show selectedRepairFixture;

void main() {
  testWidgets('narrow large text history is read-only and reload is explicit', (
    tester,
  ) async {
    final f = await selectedRepairFixture();
    var reloads = 0;
    tester.view.resetPhysicalSize();
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: MediaQuery(
            data: const MediaQueryData(textScaler: TextScaler.linear(2)),
            child: SingleChildScrollView(
              child: SelectedRepairRequestView(
                sessionId: f.origin.requestSession.sessionId,
                history: SelectedRepairHistory([
                  SelectedRepairHistoryEntry(
                    attempt: f.proposed,
                    origin: f.origin,
                    reference: SelectedRepairRequestReference.forProposed(
                      f.origin,
                      f.proposed,
                    ),
                  ),
                ], omittedProjectAttempts: 4),
                error: 'Previous history retained.',
                onReload: () => reloads++,
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
    expect(
      find.textContaining('4 older project attempts omitted'),
      findsOneWidget,
    );
    expect(find.textContaining('Requested task Tanalyze'), findsOneWidget);
    expect(find.byType(TextButton), findsOneWidget);
    expect(reloads, 0);
    await tester.ensureVisible(find.text('Reload repair history'));
    await tester.tap(find.text('Reload repair history'));
    expect(reloads, 1);
    expect(tester.takeException(), isNull);
  });
}
