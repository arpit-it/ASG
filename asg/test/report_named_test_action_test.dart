// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/requirement_check_report_controller.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/views/requirement_check_report_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'named_check_observation_test.dart' as fixtures;
import 'requirement_check_report_test.dart' show project;
import 'requirement_named_test_runner_test.dart' show Session;
import 'manual_check_observation_test.dart' show Transactions;

Future<Transactions> fixture() async {
  final records = await fixtures.fixture();
  final data = jsonDecode(records.data['studio.generation.v1.p']!);
  data['confinementVersion'] = 1;
  records.data['studio.generation.v1.p'] = jsonEncode(data);
  return records;
}

void main() {
  for (final passed in [true, false]) {
    test(
      'explicit selected outcome $passed is durable before refresh',
      () async {
        final records = await fixture();
        final session = Session()..passed = passed;
        final controller = RequirementCheckReportController(
          project,
          RequirementCheckReportStore(records),
          createNamedTestSession: () => session,
        )..load();
        final id = controller.report!.results.first.requirement.id;
        await controller.runNamedTest(id, 'Auto');
        expect(session.calls, 1);
        expect(session.disposed, isTrue);
        expect(controller.runningTest, isFalse);
        expect(controller.error, isNull);
        expect(
          controller.report!.namedObservations.single.result.passed,
          passed,
        );
        expect(controller.report!.namedObservations.single.checkId, 'Auto');
        expect(controller.evidenceJson, isNot(contains('PRIVATE_OUTPUT')));
        expect(controller.testNotice, contains('result saved'));
        controller.dispose();
      },
    );
  }

  for (final failure in ['unsupported', 'stale', 'save', 'input']) {
    test(
      '$failure retains prior evidence and shows sanitized failure',
      () async {
        final records = await fixture();
        final store = RequirementCheckReportStore(records);
        await fixtures.record(store, false);
        final before = Map<String, String>.of(records.data);
        final session = Session();
        if (failure == 'unsupported') session.supported = false;
        if (failure == 'stale') session.staleAt = 1;
        if (failure == 'save') records.fail = true;
        if (failure == 'input') {
          session.afterDispatch = () {
            final data = jsonDecode(records.data['studio.planApproval.v1.p']!);
            data['approved'] = false;
            records.data['studio.planApproval.v1.p'] = jsonEncode(data);
          };
        }
        final controller = RequirementCheckReportController(
          project,
          store,
          createNamedTestSession: () => session,
        )..load();
        await controller.runNamedTest(
          controller.report!.results.first.requirement.id,
          'Auto',
        );
        expect(controller.error, isNotNull);
        expect(controller.error, isNot(contains('PRIVATE_OUTPUT')));
        expect(controller.testNotice, isNull);
        expect(
          store.load(project).namedObservations.single.result.passed,
          isFalse,
        );
        for (final key in before.keys.where((k) => k.contains('named'))) {
          expect(records.data[key], before[key]);
        }
        expect(session.disposed, isTrue);
        controller.dispose();
      },
    );
  }

  test(
    'busy action prevents overlapping tests, inspection and manual save',
    () async {
      final records = await fixture();
      final session = Session()..gate = Completer<void>();
      final controller = RequirementCheckReportController(
        project,
        RequirementCheckReportStore(records),
        createNamedTestSession: () => session,
      )..load();
      final id = controller.report!.results.first.requirement.id;
      final pending = controller.runNamedTest(id, 'Auto');
      expect(controller.runningTest, isTrue);
      await controller.runNamedTest(id, 'Auto');
      await controller.inspectArtifacts();
      await controller.recordManualObservation(id, 'Manual', true);
      expect(controller.inspecting, isFalse);
      expect(controller.report!.manualObservations, isEmpty);
      session.gate!.complete();
      await pending;
      expect(session.calls, 1);
      controller.dispose();
    },
  );

  for (final invalidate in ['reload', 'dispose']) {
    test('$invalidate revokes pending persistence', () async {
      final records = await fixture();
      final store = RequirementCheckReportStore(records);
      final session = Session()..gate = Completer<void>();
      final controller = RequirementCheckReportController(
        project,
        store,
        createNamedTestSession: () => session,
      )..load();
      final pending = controller.runNamedTest(
        controller.report!.results.first.requirement.id,
        'Auto',
      );
      // Allow preflight to reach the owned session.
      await Future<void>.delayed(Duration.zero);
      if (invalidate == 'reload') {
        controller.load();
      } else {
        controller.dispose();
      }
      session.gate!.complete();
      await pending;
      expect(store.load(project).namedObservations, isEmpty);
      expect(session.disposed, isTrue);
      if (invalidate == 'reload') {
        expect(controller.testNotice, isNull);
        controller.dispose();
      }
    });
  }

  testWidgets(
    'narrow enlarged report explicitly runs selected test and refreshes saved result',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = await fixture();
      final session = Session()..gate = Completer<void>();
      final controller = RequirementCheckReportController(
        project,
        RequirementCheckReportStore(records),
        createNamedTestSession: () => session,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(1.5)),
            child: child!,
          ),
          home: RequirementCheckReportScreen(controller: controller),
        ),
      );
      final button = find.text('Run named test for Auto');
      await tester.scrollUntilVisible(
        button,
        250,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(tester.element(button), alignment: 0.5);
      await tester.pumpAndSettle();
      expect(session.calls, 0);
      await tester.tap(button);
      await tester.pump();
      expect(controller.runningTest, isTrue);
      expect(
        tester
            .widget<TextButton>(
              find.widgetWithText(TextButton, 'Run named test for Auto'),
            )
            .onPressed,
        isNull,
      );
      session.gate!.complete();
      await tester.pumpAndSettle();
      expect(controller.report!.namedObservations.single.result.passed, isTrue);
      await tester.scrollUntilVisible(
        find.text('Saved named-test result: passed'),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Saved named-test result: passed'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
