// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:asg/controllers/html_source_review_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/services/html/html_source_proposer.dart';
import 'package:asg/views/html_source_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'html_planning_test.dart' as html;
import 'html_source_draft_test.dart' show report;
import 'html_source_proposer_test.dart' show Provider;
import 'html_source_review_test.dart' show response;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'nonempty chunks advance progress and a new request resets it',
    () async {
      var provider = Provider();
      final proposer = HtmlSourceProposer(createProvider: (_) => provider);
      for (var attempt = 0; attempt < 2; attempt++) {
        final progress = <int>[];
        final pending = proposer.propose(
          config: const LocalModelConfig(),
          instruction: 'Greeting',
          onProgress: progress.add,
        );
        final json = response();
        provider.stream.add('');
        provider.stream.add(json.substring(0, 20));
        await Future<void>.delayed(Duration.zero);
        expect(progress, [1]);
        provider.stream.add(json.substring(20));
        await provider.stream.close();
        expect((await pending).files['index.html'], isNotEmpty);
        expect(progress, [1, 2]);
        provider = Provider();
      }
    },
  );
  test(
    'progress listener cancellation rejects a complete final chunk',
    () async {
      final provider = Provider();
      final proposer = HtmlSourceProposer(createProvider: (_) => provider);
      final pending = proposer.propose(
        config: const LocalModelConfig(),
        instruction: 'Greeting',
        onProgress: (_) {
          unawaited(proposer.cancel());
        },
      );
      final assertion = expectLater(pending, throwsStateError);
      provider.stream.add(response());
      await provider.stream.close();
      await assertion;
      expect(provider.cancellations, greaterThanOrEqualTo(1));
    },
  );
  for (final interruption in ['stop', 'dispose', 'context', 'deadline']) {
    test(
      'stream progress stops after $interruption without partial authority',
      () async {
        final records = await html.seed();
        final provider = Provider();
        final c = HtmlSourceReviewController(
          project: html.project,
          records: records,
          proposer: HtmlSourceProposer(createProvider: (_) => provider),
          inspectReferences: (_) async => report(),
          requestDeadline: interruption == 'deadline'
              ? const Duration(milliseconds: 25)
              : const Duration(seconds: 90),
        );
        addTearDown(() {
          if (!c.isDisposed) c.dispose();
        });
        final pending = c.request('Greeting');
        final json = response();
        provider.stream.add(json.substring(0, 20));
        await Future<void>.delayed(Duration.zero);
        expect(c.status, contains('Response chunks received: 1.'));
        expect(c.proposal, isNull);
        switch (interruption) {
          case 'stop':
            c.stop();
          case 'dispose':
            c.dispose();
          case 'context':
            records.values.clear();
          case 'deadline':
            await Future<void>.delayed(const Duration(milliseconds: 40));
        }
        provider.stream.add(json.substring(20));
        await provider.stream.close();
        await pending;
        expect(c.proposal, isNull);
        expect(c.status, isNot(contains('Response chunks received: 2')));
      },
    );
  }
  test(
    'controller progress listener Stop cannot publish completed source',
    () async {
      final records = await html.seed();
      final provider = Provider();
      final c = HtmlSourceReviewController(
        project: html.project,
        records: records,
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
        inspectReferences: (_) async => report(),
      );
      addTearDown(c.dispose);
      c.addListener(() {
        if (c.status.startsWith('Response chunks received:')) c.stop();
      });
      final pending = c.request('Greeting');
      provider.stream.add(response());
      await provider.stream.close();
      await pending;
      expect(c.proposal, isNull);
      expect(c.status, contains('stopped'));
    },
  );
  testWidgets(
    'view shows count-only progress, validates completion and resets replacement',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = await html.seed();
      var provider = Provider();
      final c = HtmlSourceReviewController(
        project: html.project,
        records: records,
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
        inspectReferences: (_) async => report(),
      );
      await tester.pumpWidget(
        MaterialApp(home: HtmlSourceReviewScreen(controller: c)),
      );
      final pending = c.request('Greeting');
      final json = response();
      provider.stream.add(json.substring(0, 20));
      await tester.pump();
      expect(
        find.textContaining('Response chunks received: 1.'),
        findsOneWidget,
      );
      expect(c.proposal, isNull);
      provider.stream.add(json.substring(20));
      await provider.stream.close();
      await pending;
      await tester.pump();
      expect(find.textContaining('Response chunks received: 1.'), findsNothing);
      expect(c.proposal, isNotNull);
      provider = Provider();
      final retry = c.request('Retry');
      expect(c.status, startsWith('Requesting'));
      provider.stream.add('invalid');
      await tester.pump();
      expect(
        find.textContaining('Response chunks received: 1.'),
        findsOneWidget,
      );
      await provider.stream.close();
      await retry;
      await tester.pump();
      expect(c.error, isNotNull);
      expect(c.proposal, isNotNull);
      expect(c.status, contains('Previous reviewed source is retained'));
    },
  );
}
