// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/product_acceptance_controller.dart';
import 'package:asg/models/product_acceptance_manifest.dart';
import 'package:asg/models/product_acceptance_report.dart';
import 'package:asg/services/product_acceptance_manifest_service.dart';
import 'package:asg/views/product_acceptance_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String spec() =>
    File('docs/development/product_acceptance_manifest.json')
        .readAsStringSync();
String historical() =>
    File('test/fixtures/product_acceptance_report.json').readAsStringSync();

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'bundled canonical asset matches Python collector digest and target scopes',
    () async {
      final manifest = await ProductAcceptanceManifestService().load();
      expect(
        manifest.sha256Digest,
        'd14e0d2b405bed7a8c36491d7d15f63f96a08dda536c11aff57e4905f3d9f8b0',
      );
      expect(manifest.checks.length, 29);
      expect(
        manifest.checks
            .where((c) => c.checkId == 'archive-browser')
            .single
            .target,
        'web',
      );
      expect(
        manifest.checks
            .where((c) => c.scenarioId == 'reviewed-candidate')
            .every((c) => c.target == 'macos'),
        isTrue,
      );
    },
  );
  test('collector compatibility report exposes omitted checks without changing saved cells', () {
    final manifest = ProductAcceptanceManifest.parse(spec());
    final report = ProductAcceptanceReport.parse(historical());
    final before = report.cells.map((c) => c.status).toList();
    final comparison = manifest.compare(report);
    expect(comparison.manifestMatches, isFalse);
    expect(
      comparison.absentChecks,
      contains('approved-plan / plan-lifecycle-interaction / macos'),
    );
    expect(
      comparison.absentChecks,
      contains('bounded-repair / repair-interaction / macos'),
    );
    expect(report.cells.map((c) => c.status), before);
    expect(report.cells.where((c) => c.status == 'passed').length, 1);
  });
  test('retained native report is historical after manifest change', () {
    final report = ProductAcceptanceReport.parse(
      File(
        'docs/development/acceptance/2026-10-30-native-fixture-baseline/report.json',
      ).readAsStringSync(),
    );
    final comparison = ProductAcceptanceManifest.parse(spec()).compare(report);
    expect(comparison.manifestMatches, isFalse);
    expect(report.cells.where((c) => c.status == 'passed').length, 4);
    expect(comparison.absentChecks, isEmpty);
  });
  test('newly configured target cannot hide behind old unavailable cells', () {
    final raw = jsonDecode(spec()) as Map<String, dynamic>;
    final scenario = (raw['scenarios'] as List).firstWhere(
      (s) => s['id'] == 'reviewed-candidate',
    );
    final check = (scenario['checks'] as List).firstWhere(
      (c) => c['id'] == 'model-proposal',
    );
    check['targets'] = ['macos', 'web'];
    final report = ProductAcceptanceReport.parse(
      File(
        'docs/development/acceptance/2026-10-31-native-stop-deadline/report.json',
      ).readAsStringSync(),
    );
    expect(
      ProductAcceptanceManifest.parse(jsonEncode(raw))
          .compare(report)
          .mismatchedChecks,
      contains('reviewed-candidate / model-proposal / web'),
    );
  });
  test('matching digest cannot hide omitted scenarios or changed kind/requirements', () {
    final manifest = ProductAcceptanceManifest.parse(spec());
    final raw = jsonDecode(historical()) as Map<String, dynamic>;
    raw['manifestSha256'] = manifest.sha256Digest;
    for (final cell in raw['cells']) {
      if (cell['savedEvidence'] != null) {
        cell['savedEvidence']['manifestSha256'] = manifest.sha256Digest;
        cell['status'] =
            cell['savedEvidence']['identity'].toString() ==
                raw['identity'].toString()
            ? cell['savedEvidence']['status']
            : 'stale';
        cell['currentPass'] = cell['status'] == 'passed';
      }
    }
    raw['cells'].removeWhere((cell) => cell['scenarioId'] == 'archive-reopen');
    for (final cell in raw['cells']) {
      if (cell['scenarioId'] == 'create-reopen' &&
          cell['checkId'] == 'durable-records') {
        cell['kind'] = 'manual';
        cell['requirementIds'] = ['F02'];
      }
    }
    final comparison = manifest.compare(
      ProductAcceptanceReport.parse(jsonEncode(raw)),
    );
    expect(comparison.manifestMatches, isTrue);
    expect(
      comparison.absentChecks,
      contains('archive-reopen / archive-records / macos'),
    );
    expect(
      comparison.mismatchedChecks,
      contains('create-reopen / durable-records / web'),
    );
  });
  test('loading is serialized; failure/retry, retained invalid input and clear are safe', () async {
    final pending = Completer<ProductAcceptanceManifest>();
    var calls = 0;
    final controller = ProductAcceptanceController(
      manifestLoader: () {
        calls++;
        return pending.future;
      },
    );
    final load = controller.loadManifest();
    await controller.loadManifest();
    expect(calls, 1);
    controller.inspect(historical());
    expect(controller.comparison, isNull);
    pending.completeError(StateError('/private/secret'));
    await load;
    expect(controller.manifestError, isNot(contains('/private')));
    expect(controller.report, isNotNull);
    controller.dispose();

    var fail = true;
    final retry = ProductAcceptanceController(
      manifestLoader: () async {
        if (fail) throw StateError('hidden');
        return ProductAcceptanceManifest.parse(spec());
      },
    );
    await retry.loadManifest();
    fail = false;
    await retry.loadManifest();
    retry.inspect(historical());
    final old = retry.report;
    retry.inspect('invalid');
    expect(retry.report, same(old));
    expect(retry.comparison!.manifestMatches, isFalse);
    retry.clear();
    expect(retry.comparison, isNull);
    expect(retry.manifestError, isNull);
    retry.dispose();
  });
  test('disposing during load does not publish or notify', () async {
    final pending = Completer<ProductAcceptanceManifest>();
    final controller = ProductAcceptanceController(
      manifestLoader: () => pending.future,
    );
    var notifications = 0;
    controller.addListener(() => notifications++);
    final load = controller.loadManifest();
    controller.dispose();
    pending.complete(ProductAcceptanceManifest.parse(spec()));
    await load;
    expect(notifications, 1);
    expect(controller.bundledManifestSha256, isNull);
  });
  testWidgets(
    'comparison failure retries and historical coverage is visible at narrow width',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var fail = true;
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: ProductAcceptanceScreen(
            manifestLoader: () async {
              if (fail) throw StateError('private');
              return ProductAcceptanceManifest.parse(spec());
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.byType(TextField),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), historical());
      await tester.ensureVisible(find.text('Inspect saved report'));
      await tester.tap(find.text('Inspect saved report'));
      await tester.pumpAndSettle();
      expect(find.textContaining('comparison unavailable'), findsOneWidget);
      fail = false;
      await tester.scrollUntilVisible(
        find.text('Retry manifest comparison'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Retry manifest comparison'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Historical manifest:'), findsOneWidget);
      await tester.scrollUntilVisible(
        find.text('Bundled coverage gaps'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Bundled coverage gaps'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Omitted: approved-plan'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
}
