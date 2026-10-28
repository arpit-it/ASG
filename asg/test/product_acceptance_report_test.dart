// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/product_acceptance_report.dart';
import 'package:asg/controllers/product_acceptance_controller.dart';
import 'package:asg/views/product_acceptance_screen.dart';
import 'package:asg/views/studio_home.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

String fixture() =>
    File('test/fixtures/product_acceptance_report.json').readAsStringSync();
Map<String, dynamic> data() => jsonDecode(fixture()) as Map<String, dynamic>;
void main() {
  testWidgets('home opens session-only product evidence without a project', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      MaterialApp(
        home: StudioHome(
          store: StudioStore(PreferenceRecords(preferences)),
          projects: const [],
        ),
      ),
    );
    await tester.tap(find.byTooltip('Product acceptance evidence'));
    await tester.pumpAndSettle();
    expect(find.byType(ProductAcceptanceScreen), findsOneWidget);
    expect(find.textContaining('No report loaded'), findsOneWidget);
    expect(preferences.getKeys(), isEmpty);
  });
  test(
    'Python collector output preserves six statuses and exact identities',
    () {
      final report = ProductAcceptanceReport.parse(fixture());
      expect(report.cells.length, 90);
      expect(
        report.cells.map((c) => c.status).toSet(),
        ProductAcceptanceReport.statuses.toSet(),
      );
      expect(report.cells.where((c) => c.status == 'passed').length, 1);
      expect(report.cells.first.artifactSha256.single, '0' * 64);
      expect(report.cells.first.savedIdentity, report.identity);
      expect(() => report.cells.clear(), throwsUnsupportedError);
      expect(() => report.identity.clear(), throwsUnsupportedError);
    },
  );
  test('rejects fabricated passes, mismatches, missing targets and duplicate cells', () {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (r) => r['cells'][1]['currentPass'] = true,
      (r) => r['cells'][0]['status'] = 'stale',
      (r) => r['identity']['sourceRevision'] = '0' * 40,
      (r) => r['cells'][0]['savedEvidence']['target'] = 'web',
      (r) => r['cells'][0]['savedEvidence']['artifactSha256'] = [
        '/private/secret',
      ],
      (r) => r['cells'].removeLast(),
      (r) => r['cells'][1] = r['cells'][0],
      (r) => r['cells'][0]['privatePath'] = '/private/secret',
      (r) => r['generatedAt'] = '2999-01-01T00:00:00Z',
      (r) => r['generatedAt'] = '2026-02-30T00:00:00Z',
      (r) =>
          r['cells'][0]['savedEvidence']['observedAt'] = '2026-10-28T08:00:00Z',
    ]) {
      final r = data();
      mutate(r);
      expect(
        () => ProductAcceptanceReport.parse(jsonEncode(r)),
        throwsFormatException,
      );
    }
  });
  test('rejects duplicate keys, oversized input and malformed JSON safely', () {
    for (final source in [
      '{"schemaVersion":1,"schemaVersion":1}',
      'x' * 1048577,
      '"unterminated',
      '[]',
    ]) {
      final controller = ProductAcceptanceController();
      controller.inspect(source);
      expect(controller.error, contains('Invalid saved report'));
      expect(controller.report, isNull);
      controller.dispose();
    }
  });
  test('rejects calendar year zero accepted by Dart but not the collector', () {
    final report = data();
    report['generatedAt'] = '0000-01-01T00:00:00Z';
    for (final cell in report['cells']) {
      if (cell['savedEvidence'] != null) {
        cell['savedEvidence']['observedAt'] = report['generatedAt'];
      }
    }
    expect(
      () => ProductAcceptanceReport.parse(jsonEncode(report)),
      throwsFormatException,
    );
  });
  test(
    'invalid replacement retains prior report and clear/disposal are safe',
    () {
      final controller = ProductAcceptanceController();
      controller.inspect(fixture());
      final previous = controller.report;
      controller.inspect('/private/secret');
      expect(controller.report, same(previous));
      expect(controller.error, isNot(contains('/private')));
      controller.clear();
      expect(controller.report, isNull);
      expect(controller.error, isNull);
      controller.dispose();
      controller.inspect(fixture());
      controller.clear();
      expect(controller.report, isNull);
    },
  );
  testWidgets('narrow enlarged-text screen inspects, exposes gaps and clears', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(1.5)),
          child: child!,
        ),
        home: const ProductAcceptanceScreen(),
      ),
    );
    await tester.scrollUntilVisible(
      find.byType(TextField),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), fixture());
    await tester.ensureVisible(find.text('Inspect saved report'));
    await tester.tap(find.text('Inspect saved report'));
    await tester.pumpAndSettle();
    expect(find.textContaining('cells without a saved pass'), findsOneWidget);
    await tester.scrollUntilVisible(
      find.text('android saved evidence'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('android saved evidence'));
    await tester.pumpAndSettle();
    expect(find.textContaining('saved unavailable'), findsWidgets);
    expect(tester.takeException(), isNull);
    await tester.scrollUntilVisible(
      find.text('Clear report'),
      -300,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Clear report'));
    await tester.pumpAndSettle();
    expect(find.textContaining('No report loaded'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
