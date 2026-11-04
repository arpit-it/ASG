// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:asg/controllers/html_source_review_controller.dart';
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
  for (final failure in ['transport', 'malformed', 'diagnostics']) {
    test(
      'replacement $failure preserves edited source with fresh authority',
      () async {
        final records = await html.seed();
        var provider = Provider();
        var failInspection = false;
        final c = HtmlSourceReviewController(
          project: html.project,
          records: records,
          proposer: HtmlSourceProposer(createProvider: (_) => provider),
          inspectReferences: (_) async {
            if (failInspection) throw StateError('PRIVATE diagnostics');
            return report();
          },
        );
        addTearDown(c.dispose);
        final initial = c.request('Greeting');
        provider.stream.add(response());
        await provider.stream.close();
        await initial;
        final files = {
          ...c.proposal!.files,
          'styles.css': 'main { color: orange; }',
        };
        await c.revise(c.proposal!, files);
        final old = c.proposal!;
        final provenance = c.provenance;
        final references = c.references;
        final before = Map.of(records.values);
        provider = Provider();
        failInspection = failure == 'diagnostics';
        final replacing = c.request('Replacement');
        expect(c.proposal, isNull);
        expect(() => c.authorizeProposal(old), throwsStateError);
        if (failure == 'transport') {
          provider.stream.addError(StateError('PRIVATE transport'));
        } else {
          provider.stream.add(
            failure == 'malformed' ? 'PRIVATE invalid' : response(),
          );
        }
        await provider.stream.close();
        await replacing;
        expect(c.proposal!.files, files);
        expect(c.proposal, isNot(same(old)));
        expect(c.provenance, same(provenance));
        expect(c.references, same(references));
        expect(c.locallyEdited, true);
        expect(c.status, contains('Previous reviewed source is retained'));
        expect(c.error, isNot(contains('PRIVATE')));
        expect(records.values, before);
        expect(() => c.authorizeProposal(old), throwsStateError);
        c.authorizeProposal(c.proposal!);
        final recovered = c.proposal!;
        provider = Provider();
        final repeat = c.request('Repeat');
        provider.stream.add('invalid');
        await provider.stream.close();
        await repeat;
        expect(c.proposal!.files, files);
        expect(() => c.authorizeProposal(recovered), throwsStateError);
        provider = Provider();
        failInspection = false;
        final retry = c.request('Successful replacement');
        provider.stream.add(response());
        await provider.stream.close();
        await retry;
        expect(c.error, isNull);
        expect(c.locallyEdited, false);
        expect(c.proposal!.files['styles.css'], 'main { color: navy; }');
        expect(records.values, before);
      },
    );
  }
  test('refinement sends edited source, retains failure, then replaces with fresh review', () async {
    final records = await html.seed();
    var provider = Provider();
    final c = HtmlSourceReviewController(
      project: html.project,
      records: records,
      proposer: HtmlSourceProposer(createProvider: (_) => provider),
      inspectReferences: (_) async => report(),
    );
    addTearDown(c.dispose);
    var pending = c.request('Initial');
    provider.stream.add(response());
    await provider.stream.close();
    await pending;
    await c.revise(c.proposal!, {
      ...c.proposal!.files,
      'styles.css': 'main { color: orange; }',
    });
    final edited = c.proposal!;
    final before = Map.of(records.values);
    provider = Provider();
    pending = c.request('Keep content, change color', refinement: edited);
    expect(provider.prompt, contains('main { color: orange; }'));
    expect(() => c.authorizeProposal(edited), throwsStateError);
    provider.stream.addError(StateError('failure'));
    await provider.stream.close();
    await pending;
    expect(c.proposal!.files, edited.files);
    expect(c.proposal, isNot(same(edited)));
    expect(c.locallyEdited, true);
    final recovered = c.proposal!;
    provider = Provider();
    pending = c.request('Retry refinement', refinement: recovered);
    provider.stream.add(response());
    await provider.stream.close();
    await pending;
    expect(c.proposal, isNot(same(recovered)));
    expect(c.locallyEdited, false);
    expect(c.error, isNull);
    expect(records.values, before);
  });
  test(
    'stale refinement identity and oversized source preserve current review',
    () async {
      final records = await html.seed();
      var allocations = 0;
      final provider = Provider();
      final c = HtmlSourceReviewController(
        project: html.project,
        records: records,
        proposer: HtmlSourceProposer(
          createProvider: (_) {
            allocations++;
            return provider;
          },
        ),
        inspectReferences: (_) async => report(),
      );
      addTearDown(c.dispose);
      final pending = c.request('Initial');
      provider.stream.add(response());
      await provider.stream.close();
      await pending;
      final old = c.proposal!;
      await c.revise(old, {...old.files, 'styles.css': 'é' * 12000});
      final current = c.proposal!;
      for (final base in [old, current]) {
        await c.request('Refine', refinement: base);
        expect(c.proposal, same(current));
        expect(c.error, contains('Cannot refine'));
        expect(allocations, 1);
      }
      records.values['studio.chat.v1.html-plan'] = 'changed';
      await c.request('Refine', refinement: current);
      expect(c.proposal, isNull);
      expect(allocations, 1);
    },
  );
  for (final action in ['stop', 'dispose', 'context', 'deadline']) {
    test('refinement ignores late source after $action', () async {
      final records = await html.seed();
      var provider = Provider();
      final c = HtmlSourceReviewController(
        project: html.project,
        records: records,
        requestDeadline: const Duration(milliseconds: 100),
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
        inspectReferences: (_) async => report(),
      );
      final initial = c.request('Initial');
      provider.stream.add(response());
      await provider.stream.close();
      await initial;
      final base = c.proposal!;
      provider = Provider();
      final pending = c.request('Refine', refinement: base);
      await c.request('Overlap', refinement: base);
      if (action == 'stop') c.stop();
      if (action == 'dispose') c.dispose();
      if (action == 'context') {
        records.values['studio.chat.v1.html-plan'] = 'changed';
      }
      if (action == 'deadline') {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
      provider.stream.add(response());
      await provider.stream.close();
      await pending;
      expect(c.proposal, isNull);
      expect(c.busy, false);
      expect(() => c.authorizeProposal(base), throwsStateError);
      if (action != 'dispose') c.dispose();
    });
  }
  for (final action in ['stop', 'dispose', 'context', 'deadline', 'stale']) {
    testWidgets('failed replacement cannot recover after $action', (
      tester,
    ) async {
      final records = await html.seed();
      var provider = Provider();
      final c = HtmlSourceReviewController(
        project: html.project,
        records: records,
        requestDeadline: const Duration(seconds: 1),
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
        inspectReferences: (_) async => report(),
      );
      final initial = c.request('Greeting');
      provider.stream.add(response());
      await provider.stream.close();
      await initial;
      final old = c.proposal!;
      if (action == 'stale') {
        records.values['studio.chat.v1.html-plan'] = 'changed before';
      }
      provider = Provider();
      final replacing = c.request('Replacement');
      if (action == 'stop') c.stop();
      if (action == 'dispose') c.dispose();
      if (action == 'context') {
        records.values['studio.chat.v1.html-plan'] = 'changed during';
      }
      if (action == 'deadline') await tester.pump(const Duration(seconds: 2));
      provider.stream.addError(StateError('PRIVATE failure'));
      await provider.stream.close();
      await replacing;
      expect(c.proposal, isNull);
      expect(c.provenance, isNull);
      expect(c.references, isNull);
      expect(c.status, isNot(contains('Previous reviewed source is retained')));
      expect(() => c.authorizeProposal(old), throwsStateError);
      expect(c.busy, false);
      expect(c.error, isNot(contains('PRIVATE')));
      if (action != 'dispose') c.dispose();
    });
  }
  testWidgets('320px 2x request failure retains source and permits retry', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
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
    final initial = c.request('Greeting');
    provider.stream.add(response());
    await provider.stream.close();
    await initial;
    final old = c.proposal!;
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
    Future<void> reveal(Finder finder, [double delta = 180]) async {
      await tester.scrollUntilVisible(
        finder,
        delta,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
    }

    await reveal(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'Replacement');
    provider = Provider();
    await reveal(find.text('Refine reviewed source'));
    await tester.tap(find.text('Refine reviewed source'));
    await tester.pump();
    expect(provider.prompt, contains('main { color: navy; }'));
    provider.stream.addError(StateError('PRIVATE transport'));
    unawaited(provider.stream.close());
    await tester.pumpAndSettle();
    expect(c.proposal!.files, old.files);
    await reveal(find.text(c.status));
    expect(find.text(c.status), findsOneWidget);
    await reveal(find.text('Export reviewed source…'));
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Export reviewed source…'),
          )
          .onPressed,
      isNotNull,
    );
    await reveal(find.text('Request source for review'), -180);
    provider = Provider();
    await tester.tap(find.text('Request source for review'));
    await tester.pump();
    provider.stream.add(response());
    unawaited(provider.stream.close());
    await tester.pumpAndSettle();
    expect(c.error, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
