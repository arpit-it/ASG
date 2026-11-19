// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/candidate_repair_lineage.dart';
import 'package:asg/views/candidate_repair_lineage_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'candidate_repair_lineage_test.dart' show linkedRepairFixture;

void main() {
  testWidgets(
    'narrow enlarged repair lineage shows exact detached facts without actions',
    (tester) async {
      final f = await linkedRepairFixture();
      f.lineage.requireContext(
        jsonEncode(f.context.toJson()),
        f.run,
        f.origin,
        f.attempt,
      );
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(2)),
              child: SingleChildScrollView(
                child: CandidateRepairLineageView(
                  review: CandidateRepairLineageReview(
                    f.lineage,
                    f.origin,
                    f.attempt,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      expect(tester.takeException(), isNull);
      expect(find.text('Repair request 1 → candidate run 2'), findsOneWidget);
      expect(find.textContaining('task Tanalyze'), findsOneWidget);
      expect(
        find.textContaining('Selected input lib/main.dart'),
        findsOneWidget,
      );
      expect(
        find.textContaining('supplied-candidate-response-model'),
        findsOneWidget,
      );
      expect(find.byType(TextButton), findsNothing);
      expect(find.byType(OutlinedButton), findsNothing);
      expect(find.byType(ElevatedButton), findsNothing);
    },
  );
  testWidgets('unavailable optional repair lineage has no inferred fallback', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CandidateRepairLineageView(review: null)),
      ),
    );
    expect(
      find.textContaining('Repair request lineage is unavailable'),
      findsOneWidget,
    );
    expect(find.byType(TextButton), findsNothing);
  });
}
