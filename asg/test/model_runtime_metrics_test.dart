// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/model_runtime_metrics.dart';
import 'package:asg/services/local_model.dart';
import 'package:asg/views/model_runtime_metrics_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const metrics = {
  'finish_reason': 'stop',
  'prompt_tokens': 17,
  'completion_tokens': 2,
  'tokens_per_second': 12.5,
  'peak_memory_gb': 6.25,
  'private_debug': 'never display this',
};
Map<String, Object> response({Object? reported = metrics}) => {
  'choices': [
    {
      'message': {'content': 'Ready'},
      'finish_reason': 'stop',
    },
  ],
  'metrics': ?reported,
};
String event(Object value) => 'data: ${jsonEncode(value)}\n\n';
String streamStart({String reason = 'stop'}) =>
    event({
      'choices': [
        {
          'delta': {'content': 'Ready'},
        },
      ],
    }) +
    event({
      'choices': [
        {'delta': <String, Object>{}, 'finish_reason': reason},
      ],
      'metrics': metrics,
    });

void main() {
  test(
    'optional telemetry validates bounded numbers without private fields',
    () {
      final parsed = ModelRuntimeMetrics.parse(metrics, outputLimit: 256)!;
      expect(parsed.promptTokens, 17);
      expect(parsed.completionTokens, 2);
      expect(parsed.tokensPerSecond, 12.5);
      expect(parsed.peakMemoryGb, 6.25);
      for (final bad in [
        null,
        [],
        'secret',
        {...metrics, 'finish_reason': 'length'},
        {...metrics, 'prompt_tokens': 1.5},
        {...metrics, 'prompt_tokens': -1},
        {...metrics, 'completion_tokens': true},
        {...metrics, 'completion_tokens': 257},
      ]) {
        expect(ModelRuntimeMetrics.parse(bad, outputLimit: 256), isNull);
      }
      for (final bad in ['private', double.nan, double.infinity, -1, 1e10]) {
        final parsed = ModelRuntimeMetrics.parse({
          ...metrics,
          'tokens_per_second': bad,
          'peak_memory_gb': bad,
        }, outputLimit: 256)!;
        expect(parsed.tokensPerSecond, isNull);
        expect(parsed.peakMemoryGb, isNull);
      }
    },
  );

  test(
    'JSON text remains usable with absent or malformed optional metrics',
    () async {
      for (final reported in [
        metrics,
        null,
        'private-invalid',
        {...metrics, 'completion_tokens': 999},
      ]) {
        final provider = LocalModelProvider(
          const LocalModelConfig(),
          client: MockClient(
            (_) async =>
                http.Response(jsonEncode(response(reported: reported)), 200),
          ),
        );
        expect(provider.completedMetrics, isNull);
        expect(await provider.generate('test').join(), 'Ready');
        expect(
          provider.completedMetrics?.promptTokens,
          identical(reported, metrics) ? 17 : null,
        );
        await provider.cancel();
        expect(provider.completedMetrics, isNull);
      }
    },
  );

  test(
    'SSE holds telemetry until DONE and discards failures and truncation',
    () async {
      for (final end in [
        'data: [DONE]\n\n',
        '',
        event({'error': 'private'}),
        event({
          'choices': [
            {'delta': {}, 'finish_reason': 'length'},
          ],
        }),
      ]) {
        final bytes = StreamController<List<int>>();
        final provider = LocalModelProvider(
          const LocalModelConfig(),
          client: MockClient.streaming(
            (_, _) async => http.StreamedResponse(
              bytes.stream,
              200,
              headers: {'content-type': 'text/event-stream'},
            ),
          ),
        );
        final completed = provider.generate('test').join();
        // Attach the failure assertion before delivering asynchronous errors.
        final checked = end == 'data: [DONE]\n\n'
            ? expectLater(completed, completion('Ready'))
            : expectLater(completed, throwsStateError);
        bytes.add(utf8.encode(streamStart()));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(provider.completedMetrics, isNull);
        bytes.add(utf8.encode(end));
        await bytes.close();
        await checked;
        expect(
          provider.completedMetrics?.completionTokens,
          end == 'data: [DONE]\n\n' ? 2 : null,
        );
        await provider.cancel();
      }
    },
  );

  testWidgets('telemetry and honest guidance remain readable at 320px and 2x', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            child: ModelRuntimeMetricsView(
              metrics: ModelRuntimeMetrics.parse(metrics, outputLimit: 256)!,
            ),
          ),
        ),
      ),
    );
    final guidance = find.text(ModelRuntimeMetrics.guidance);
    await tester.ensureVisible(guidance);
    expect(guidance, findsOneWidget);
    expect(find.textContaining('12.50 tokens/s'), findsOneWidget);
    expect(find.textContaining('6.25 GB'), findsOneWidget);
    expect(find.textContaining('never display'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
