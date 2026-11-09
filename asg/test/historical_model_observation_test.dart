// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:io';

import 'package:asg/controllers/historical_model_observation_controller.dart';
import 'package:asg/services/historical_model_observation_store.dart';
import 'package:asg/views/historical_model_observation_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

String report() =>
    File(HistoricalModelObservationStore.asset).readAsStringSync();

void main() {
  test(
    'exact retained evidence loads with workload and cumulative metrics',
    () async {
      final store = HistoricalModelObservationStore(read: () async => report());
      final value = await store.load();
      expect(value.recordedAt, DateTime.utc(2026, 11, 9, 18, 56, 12));
      expect(value.runs.map((run) => run.completionTokens), [2, 10, 2]);
      expect(value.runs[1].tokensPerSecond, closeTo(22.3368, .001));
      expect(value.runs[2].mlxPeakGb, closeTo(15.492977, .001));
      expect(value.weightBytes, 16054541349);
      expect(value.disconnectSeconds, .212);
      expect(() => value.runs.clear(), throwsUnsupportedError);
    },
  );

  test(
    'changed, oversized, missing and malformed assets fail privately',
    () async {
      for (final text in ['${report()} ', '{}', 'PRIVATE' * 3000]) {
        await expectLater(
          HistoricalModelObservationStore(read: () async => text).load(),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'message',
              isNot(contains('PRIVATE')),
            ),
          ),
        );
      }
      await expectLater(
        HistoricalModelObservationStore(
          read: () async => throw Exception('/PRIVATE/path'),
        ).load(),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            isNot(contains('PRIVATE')),
          ),
        ),
      );
    },
  );

  test(
    'controller retry, exclusion, caching and disposed completion',
    () async {
      var reads = 0;
      final gate = Completer<String>();
      final controller = HistoricalModelObservationController(
        store: HistoricalModelObservationStore(
          read: () async {
            reads++;
            if (reads == 1) throw Exception('PRIVATE');
            return gate.future;
          },
        ),
      );
      await controller.load();
      expect(controller.error, isNot(contains('PRIVATE')));
      final pending = controller.load();
      await controller.load();
      expect(reads, 2);
      gate.complete(report());
      await pending;
      expect(controller.observation, isNotNull);
      expect(controller.error, isNull);
      await controller.load();
      expect(reads, 2);
      controller.dispose();

      final late = Completer<String>();
      final disposed = HistoricalModelObservationController(
        store: HistoricalModelObservationStore(read: () => late.future),
      );
      final work = disposed.load();
      disposed.dispose();
      late.complete(report());
      await work;
      expect(disposed.observation, isNull);
    },
  );

  testWidgets('offline bundled asset and narrow enlarged report with retry', (
    tester,
  ) async {
    // Exercise the production asset path before injecting a failed read.
    expect((await HistoricalModelObservationStore().load()).runs, hasLength(3));
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var reads = 0;
    final controller = HistoricalModelObservationController(
      store: HistoricalModelObservationStore(
        read: () async {
          if (++reads == 1) throw Exception('PRIVATE');
          return report();
        },
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: Scaffold(
            body: SingleChildScrollView(
              child: HistoricalModelObservationPanel(controller: controller),
            ),
          ),
        ),
      ),
    );
    expect(reads, 0);
    await tester.tap(find.text('Historical Qwen3.8 27B MLX observation'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Retry historical report'));
    await tester.tap(find.text('Retry historical report'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.textContaining('Structured SSE:'));
    expect(find.textContaining('31 prompt / 10 completion'), findsOneWidget);
    expect(find.textContaining('MLX peak memory'), findsNWidgets(3));
    expect(find.textContaining('MLX peak memory 15.49 GB'), findsNWidgets(2));
    expect(find.textContaining('Checkpoint metadata hashes'), findsOneWidget);
    expect(find.textContaining('process high-water'), findsNothing);
    expect(find.textContaining('probe input hashes'), findsNothing);
    await tester.ensureVisible(find.textContaining('Tiny warm workloads'));
    expect(tester.takeException(), isNull);
    expect(find.textContaining('PRIVATE'), findsNothing);
  });
}
