// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/imported_advisory_store.dart';
import 'package:asg/services/model_settings_store.dart';
import 'package:asg/views/imported_advisory_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_plan_test.dart' show Records;
import 'imported_advisory_test.dart' show AdvisoryProvider, controller;

Future<void> openDialog(WidgetTester tester) async {
  await tester.scrollUntilVisible(
    find.byType(TextField),
    180,
    scrollable: find.byType(Scrollable).first,
  );
  await tester.enterText(
    find.byType(TextField),
    'Explain captured constraints',
  );
  await tester.ensureVisible(find.text('Review and send question'));
  await tester.tap(find.text('Review and send question'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'source question consent names source and cancellation sends nothing',
    (tester) async {
      final records = Records(), p = AdvisoryProvider();
      final c = await controller(records, p, source: true);
      await tester.pumpWidget(
        MaterialApp(home: ImportedAdvisoryScreen(controller: c)),
      );
      expect(find.text('Review captured source'), findsOneWidget);
      await openDialog(tester);
      expect(
        find.textContaining(
          'Captured source text is not copied into this answer record',
        ),
        findsOneWidget,
      );
      expect(p.calls, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(p.calls, 0);
      await tester.tap(find.text('Review and send question'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send question'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      expect(p.calls, 1);
      expect(c.saved, isNotNull);
    },
  );
  testWidgets(
    'confirmation separates captured-data transfer from local answer storage and cancel retains question',
    (tester) async {
      final records = Records(),
          p = AdvisoryProvider(),
          c = await controller(records, p);
      await tester.pumpWidget(
        MaterialApp(home: ImportedAdvisoryScreen(controller: c)),
      );
      await openDialog(tester);
      final writes = records.writes;
      expect(
        find.textContaining('Destination: http://127.0.0.1:8765/v1/'),
        findsOneWidget,
      );
      expect(
        find.textContaining('Requested model: Qwen3.8-27B-4bit'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Captured document text is not copied into this answer record',
        ),
        findsOneWidget,
      );
      expect(p.calls, 0);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(p.calls, 0);
      expect(records.writes, writes);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Explain captured constraints',
      );
      await tester.tap(find.text('Review and send question'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send question'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      expect(p.calls, 1);
      expect(c.saved, isNotNull);
      expect(c.error, isNull);
      await tester.scrollUntilVisible(
        find.text('Last saved advisory answer · historical, unverified'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(p.text), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'settings change while confirmation is open refuses dispatch without deleting text',
    (tester) async {
      final records = Records(),
          p = AdvisoryProvider(),
          c = await controller(records, p);
      await tester.pumpWidget(
        MaterialApp(home: ImportedAdvisoryScreen(controller: c)),
      );
      await openDialog(tester);
      await ModelSettingsStore(records)
          .save(const LocalModelConfig(chatOutputTokens: 512));
      final writes = records.writes;
      await tester.tap(find.text('Send question'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      expect(p.calls, 0);
      expect(c.error, isNotNull);
      expect(records.writes, writes);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Explain captured constraints',
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'replaced controller revokes old dialog consent and clears previous question',
    (tester) async {
      final records = Records(),
          oldProvider = AdvisoryProvider(),
          old = await controller(records, oldProvider);
      await tester.pumpWidget(
        MaterialApp(home: ImportedAdvisoryScreen(controller: old)),
      );
      await openDialog(tester);
      final nextProvider = AdvisoryProvider(),
          next = await controller(records, nextProvider);
      await tester.pumpWidget(
        MaterialApp(home: ImportedAdvisoryScreen(controller: next)),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Send question'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      expect(old.isDisposed, true);
      expect(oldProvider.calls, 0);
      expect(nextProvider.calls, 0);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
      await tester.pumpWidget(const SizedBox());
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'failed save shows retained answer and retry performs no second request',
    (tester) async {
      final records = Records(),
          p = AdvisoryProvider(),
          c = await controller(records, p);
      await tester.pumpWidget(
        MaterialApp(home: ImportedAdvisoryScreen(controller: c)),
      );
      await openDialog(tester);
      records.fail = true;
      await tester.tap(find.text('Send question'));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      });
      await tester.pumpAndSettle();
      expect(c.unsaved, isNotNull);
      expect(p.calls, 1);
      await tester.scrollUntilVisible(
        find.text('Retry saving'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      records.fail = false;
      await tester.tap(find.text('Retry saving'));
      await tester.pumpAndSettle();
      expect(c.unsaved, isNull);
      expect(c.saved, isNotNull);
      expect(p.calls, 1);
      expect(
        records.values.containsKey(ImportedAdvisoryStore.key('/project')),
        true,
      );
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets(
    'narrow enlarged-text sharing disclosure scrolls without overflow',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = await controller(Records(), AdvisoryProvider());
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ImportedAdvisoryScreen(controller: c),
        ),
      );
      await openDialog(tester);
      expect(find.text('Send question'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(c.saved, isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
