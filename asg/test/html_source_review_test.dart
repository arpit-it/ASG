// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/html_source_review_controller.dart';
import 'package:asg/services/html/html_source_proposer.dart';
import 'package:asg/services/html/html_starter_store.dart';
import 'package:asg/views/html_source_review_screen.dart';
import 'package:asg/views/html_project_workspace.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'html_planning_test.dart' as html;
import 'html_source_proposer_test.dart' show Provider;

String response() => jsonEncode({
  'summary': 'Local greeting',
  'files': {
    'index.html': '<main>Greeting</main>',
    'styles.css': 'main { color: navy; }',
    'app.js': 'document.title = "Greeting";',
  },
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'explicit review retains immutable artifact and provenance without writes',
    () async {
      final records = await html.seed();
      final before = Map.of(records.values);
      final provider = Provider();
      final c = HtmlSourceReviewController(
        project: html.project,
        records: records,
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
      );
      addTearDown(c.dispose);
      expect(provider.prompt, isNull);
      final request = c.request('Greeting page');
      await c.request('Overlap');
      provider.stream.add(response());
      await provider.stream.close();
      await request;
      expect(c.busy, false);
      expect(c.proposal!.files.length, 3);
      expect(c.provenance!.outputTokens, 4096);
      expect(c.error, isNull);
      expect(records.values, before);
    },
  );

  for (final key in [
    'studio.projects.v1',
    HtmlStarterStore.key,
    'studio.requirements.v1.html-plan',
    'studio.chat.v1.html-plan',
    'studio.planApproval.v1.html-plan',
  ]) {
    test('changed $key suppresses pending and retained review', () async {
      final records = await html.seed();
      final provider = Provider();
      final c = HtmlSourceReviewController(
        project: html.project,
        records: records,
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
      );
      addTearDown(c.dispose);
      final pending = c.request('Greeting');
      records.values[key] = 'PRIVATE /source';
      provider.stream.add(response());
      await provider.stream.close();
      await pending;
      expect(c.proposal, isNull);
      expect(c.error, isNot(contains('PRIVATE')));

      final freshRecords = await html.seed();
      final p = Provider();
      final retained = HtmlSourceReviewController(
        project: html.project,
        records: freshRecords,
        proposer: HtmlSourceProposer(createProvider: (_) => p),
      );
      addTearDown(retained.dispose);
      final ready = retained.request('Greeting');
      p.stream.add(response());
      await p.stream.close();
      await ready;
      expect(retained.proposal, isNotNull);
      freshRecords.values[key] = 'changed';
      expect(retained.proposal, isNull);
      expect(retained.provenance, isNull);
      expect(retained.stale, true);
    });
  }

  test('invalid instruction, corrupt metadata/settings refuse before provider creation', () async {
    final records = await html.seed();
    var calls = 0;
    final c = HtmlSourceReviewController(
      project: html.project,
      records: records,
      proposer: HtmlSourceProposer(
        createProvider: (_) {
          calls++;
          return Provider();
        },
      ),
    );
    addTearDown(c.dispose);
    for (final input in ['', ' ' * 2, 'a' * 8001]) {
      await c.request(input);
    }
    records.values['studio.localModel.v1'] = 'invalid';
    await c.request('Greeting');
    records.values.remove('studio.localModel.v1');
    records.values[HtmlStarterStore.key] = 'invalid';
    await c.request('Greeting');
    expect(calls, 0);
    expect(c.busy, false);
    expect(c.error, isNotNull);
  });

  for (final action in ['stop', 'dispose', 'listener']) {
    test('$action revokes request and late result', () async {
      final records = await html.seed();
      final provider = Provider();
      final c = HtmlSourceReviewController(
        project: html.project,
        records: records,
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
      );
      if (action == 'listener') {
        c.addListener(() {
          if (c.busy) c.stop();
        });
      }
      final pending = c.request('Greeting');
      if (action == 'stop') c.stop();
      if (action == 'dispose') c.dispose();
      if (action != 'listener') {
        provider.stream.add(response());
        await provider.stream.close();
      }
      await pending;
      expect(c.proposal, isNull);
      if (action == 'listener') expect(provider.prompt, isNull);
      if (action != 'dispose') c.dispose();
    });
  }

  test(
    'deadline revokes result and excludes overlap until cleanup settles',
    () async {
      final records = await html.seed();
      final provider = Provider()..cleanup = Completer();
      var calls = 0;
      final c = HtmlSourceReviewController(
        project: html.project,
        records: records,
        requestDeadline: const Duration(milliseconds: 1),
        proposer: HtmlSourceProposer(
          createProvider: (_) {
            calls++;
            return provider;
          },
        ),
      );
      addTearDown(c.dispose);
      final pending = c.request('Greeting');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.status, contains('deadline'));
      provider.stream.add(response());
      unawaited(provider.stream.close());
      await Future<void>.delayed(Duration.zero);
      await c.request('Overlap');
      expect(calls, 1);
      expect(c.busy, true);
      provider.cleanup!.complete();
      await pending;
      expect(c.proposal, isNull);
      expect(c.busy, false);
    },
  );

  test('cleanup failure is private and explicit retry works', () async {
    final records = await html.seed();
    var provider = Provider()..failCleanup = true;
    final c = HtmlSourceReviewController(
      project: html.project,
      records: records,
      proposer: HtmlSourceProposer(createProvider: (_) => provider),
    );
    addTearDown(c.dispose);
    final pending = c.request('Greeting');
    c.stop();
    provider.stream.add(response());
    await provider.stream.close();
    await pending;
    expect(c.error, contains('cleanup failed'));
    expect(c.proposal, isNull);
    provider = Provider();
    final retry = c.request('Greeting');
    provider.stream.add(response());
    await provider.stream.close();
    await retry;
    expect(c.error, isNull);
    expect(c.proposal, isNotNull);
  });

  testWidgets('320px 2x review renders complete files and reachable request', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = await html.seed();
    final provider = Provider();
    final c = HtmlSourceReviewController(
      project: html.project,
      records: records,
      proposer: HtmlSourceProposer(createProvider: (_) => provider),
    );
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: HtmlSourceReviewScreen(controller: c),
      ),
    );
    await tester.scrollUntilVisible(
      find.byType(TextField),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(find.byType(TextField), 'Greeting page');
    await tester.scrollUntilVisible(
      find.text('Request source for review'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('Request source for review'));
    await tester.pump();
    expect(c.busy, true);
    provider.stream.add(response());
    unawaited(provider.stream.close());
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('app.js'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('app.js'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    expect(c.isDisposed, true);
  });

  testWidgets('workspace exposes explicit review navigation', (tester) async {
    final records = await html.seed();
    await tester.pumpWidget(
      MaterialApp(
        home: HtmlProjectWorkspace(project: html.project, records: records),
      ),
    );
    await tester.scrollUntilVisible(
      find.text('Review new HTML source'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Review new HTML source'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review new HTML source'));
    await tester.pumpAndSettle();
    expect(find.byType(HtmlSourceReviewScreen), findsOneWidget);
    expect(find.text('HTML instructions'), findsOneWidget);
  });
}
