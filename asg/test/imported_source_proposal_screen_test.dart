// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:asg/views/imported_source_proposal_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_source_proposal_controller_test.dart' as fixture;

void main() {
  testWidgets(
    'author preview keeps invalid replacement and previous comparison',
    (tester) async {
      final records = await fixture.proposalRecords();
      final c = fixture.proposalController(records);
      await tester.pumpWidget(
        MaterialApp(home: ImportedSourceProposalScreen(controller: c)),
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Changed literal source');
      await tester.ensureVisible(find.text('Preview read-only diff'));
      await tester.tap(find.text('Preview read-only diff'));
      await tester.pumpAndSettle();
      expect(c.proposal!.replacement, 'Changed literal source');
      final previous = c.proposal;
      await tester.ensureVisible(find.byType(TextField));
      final oversized = List.filled(16385, 'x').join();
      await tester.enterText(find.byType(TextField), oversized);
      await tester.ensureVisible(find.text('Preview read-only diff'));
      await tester.tap(find.text('Preview read-only diff'));
      await tester.pumpAndSettle();
      expect(c.proposal, same(previous));
      expect(c.stale, isTrue);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        oversized,
      );
      expect(records.updatesSeen, everyElement(isEmpty));
      await tester.pumpWidget(const SizedBox());
      expect(c.isDisposed, isTrue);
    },
  );
  testWidgets('review scrolls at narrow width and large text', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final c = fixture.proposalController(await fixture.proposalRecords());
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: ImportedSourceProposalScreen(controller: c),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(TextField),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byType(TextField), 'Replacement');
    await tester.scrollUntilVisible(
      find.text('Preview read-only diff'),
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Preview read-only diff'));
    await tester.pumpAndSettle();
    expect(c.proposal, isNotNull);
    expect(tester.takeException(), isNull);
  });
}
