// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/html_source_review_controller.dart';
import 'package:asg/models/html/html_reference_report.dart';
import 'package:asg/services/html/html_source_proposer.dart';
import 'package:asg/views/html_source_editor.dart';
import 'package:asg/views/html_project_workspace.dart';
import 'package:asg/views/html_source_review_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'html_planning_test.dart' as seed;
import 'html_source_draft_test.dart' as drafts;
import 'html_source_proposer_test.dart' show Provider;
import 'html_source_review_test.dart' show response;

HtmlReferenceReport report() =>
    HtmlReferenceReport(elements: 1, references: 0, findings: 0, messages: []);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'edits recheck references and revoke old identity without writes/inference',
    () async {
      final records = await seed.seed();
      final before = Map.of(records.values);
      final provider = Provider();
      var modelCalls = 0, inspections = 0;
      final analysis = Completer<HtmlReferenceReport>();
      final c = HtmlSourceReviewController(
        project: seed.project,
        records: records,
        proposer: HtmlSourceProposer(
          createProvider: (_) {
            modelCalls++;
            return provider;
          },
        ),
        inspectReferences: (_) =>
            ++inspections == 1 ? Future.value(report()) : analysis.future,
      );
      addTearDown(c.dispose);
      final request = c.request('Greeting');
      provider.stream.add(response());
      await provider.stream.close();
      await request;
      final old = c.proposal!;
      final pending = c.revise(old, {
        'index.html': '<main id="edit">Edited</main>',
        'styles.css': 'main{color:red}',
      });
      expect(c.busy, true);
      expect(c.proposal, isNull);
      expect(() => c.authorizeProposal(old), throwsStateError);
      await c.revise(old, old.files);
      await c.request('Overlap');
      expect(inspections, 2);
      analysis.complete(report());
      await pending;
      expect(c.proposal!.files['index.html'], contains('Edited'));
      expect(c.proposal!.files.containsKey('app.js'), false);
      expect(() => c.authorizeProposal(old), throwsStateError);
      c.authorizeProposal(c.proposal!);
      expect(c.locallyEdited, true);
      expect(c.provenance!.model, isNotEmpty);
      expect(modelCalls, 1);
      expect(records.values, before);
      expect(
        () => c.proposal!.files['index.html'] = 'mutate',
        throwsUnsupportedError,
      );
    },
  );

  test('failed edited diagnostics retry exact editor without reviving export authority', () async {
    final records = await seed.seed();
    final before = Map.of(records.values);
    final provider = Provider();
    var inspections = 0, calls = 0;
    final c = HtmlSourceReviewController(
      project: seed.project,
      records: records,
      proposer: HtmlSourceProposer(
        createProvider: (_) {
          calls++;
          return provider;
        },
      ),
      inspectReferences: (_) async {
        inspections++;
        if (inspections == 2 || inspections == 3) throw StateError('PRIVATE');
        return report();
      },
    );
    addTearDown(c.dispose);
    final request = c.request('Greeting');
    provider.stream.add(response());
    await provider.stream.close();
    await request;
    final old = c.proposal!;
    final files = {...old.files, 'index.html': '<main>Retried edit</main>'};
    for (var attempt = 0; attempt < 2; attempt++) {
      await c.revise(old, files);
      expect(c.proposal, isNull);
      expect(c.error, contains('inspection failed'));
      expect(() => c.authorizeProposal(old), throwsStateError);
    }
    final corrected = {...files, 'styles.css': 'main{color:orange}'};
    await c.revise(old, corrected);
    expect(c.proposal!.files, corrected);
    expect(c.proposal, isNot(same(old)));
    expect(c.locallyEdited, true);
    expect(c.error, isNull);
    c.authorizeProposal(c.proposal!);
    expect(() => c.authorizeProposal(old), throwsStateError);
    expect(inspections, 4);
    expect(calls, 1);
    expect(records.values, before);
  });

  test('invalid edits retain draft authority; inspection errors never restore old authority', () async {
    final provider = Provider();
    var inspections = 0;
    final c = HtmlSourceReviewController(
      project: seed.project,
      records: await seed.seed(),
      proposer: HtmlSourceProposer(createProvider: (_) => provider),
      inspectReferences: (_) async {
        if (++inspections > 1) throw StateError('PRIVATE');
        return report();
      },
    );
    addTearDown(c.dispose);
    final request = c.request('Greeting');
    provider.stream.add(response());
    await provider.stream.close();
    await request;
    final old = c.proposal!;
    for (final files in [
      {'index.html': '', 'styles.css': 'a{}'},
      {'index.html': 'a', 'styles.css': 'é' * 40000},
      {...old.files, '../escape': 'bad'},
    ]) {
      await c.revise(old, files);
      expect(c.proposal, same(old));
      expect(c.error, contains('invalid'));
    }
    expect(inspections, 1);
    await c.revise(old, old.files);
    expect(c.proposal, isNull);
    expect(c.error, isNot(contains('PRIVATE')));
    expect(() => c.authorizeProposal(old), throwsStateError);
  });

  for (final replacement in ['request', 'restore']) {
    test('new $replacement revokes failed editor retry', () async {
      final provider = Provider();
      var inspections = 0;
      final c = HtmlSourceReviewController(
        project: seed.project,
        records: await drafts.records(),
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
        inspectReferences: (_) async {
          if (++inspections == 2) throw StateError('PRIVATE');
          return report();
        },
      );
      addTearDown(c.dispose);
      final request = c.request('Greeting');
      provider.stream.add(response());
      await provider.stream.close();
      await request;
      final old = c.proposal!;
      await c.saveDraft();
      expect(c.savedDraftAvailable, true);
      await c.revise(old, old.files);
      expect(c.error, contains('inspection failed'));
      if (replacement == 'request') {
        await c.request('New request');
      } else {
        await c.restoreDraft();
        expect(c.proposal, isNotNull);
      }
      final current = c.proposal;
      final count = inspections;
      await c.revise(old, old.files);
      expect(inspections, count);
      expect(c.proposal, same(current));
      expect(() => c.authorizeProposal(old), throwsStateError);
    });
  }

  for (final action in ['stop', 'dispose', 'context', 'deadline']) {
    testWidgets('failed edit retry is revoked by $action', (tester) async {
      final records = await seed.seed();
      final provider = Provider();
      var inspections = 0;
      final analysis = Completer<HtmlReferenceReport>();
      final c = HtmlSourceReviewController(
        project: seed.project,
        records: records,
        requestDeadline: const Duration(seconds: 1),
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
        inspectReferences: (_) {
          inspections++;
          if (inspections == 1) return Future.value(report());
          if (inspections == 2) return Future.error(StateError('PRIVATE'));
          return analysis.future;
        },
      );
      final request = c.request('Greeting');
      provider.stream.add(response());
      await provider.stream.close();
      await request;
      final old = c.proposal!;
      await c.revise(old, old.files);
      expect(c.proposal, isNull);
      final retry = c.revise(old, old.files);
      expect(inspections, 3);
      if (action == 'stop') c.stop();
      if (action == 'dispose') c.dispose();
      if (action == 'context') {
        records.values['studio.chat.v1.html-plan'] = 'changed';
      }
      if (action == 'deadline') await tester.pump(const Duration(seconds: 2));
      analysis.completeError(StateError('PRIVATE retry'));
      await retry;
      await c.revise(old, old.files);
      expect(inspections, 3);
      expect(c.proposal, isNull);
      expect(c.busy, false);
      expect(() => c.authorizeProposal(old), throwsStateError);
      expect(c.error, isNot(contains('PRIVATE')));
      if (action != 'dispose') c.dispose();
    });
  }

  for (final action in ['stop', 'dispose', 'context', 'deadline', 'listener']) {
    testWidgets('$action excludes late edited result and prior authority', (
      tester,
    ) async {
      final records = await seed.seed();
      final provider = Provider();
      final analysis = Completer<HtmlReferenceReport>();
      var inspections = 0;
      final c = HtmlSourceReviewController(
        project: seed.project,
        records: records,
        requestDeadline: const Duration(seconds: 1),
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
        inspectReferences: (_) =>
            ++inspections == 1 ? Future.value(report()) : analysis.future,
      );
      final request = c.request('Greeting');
      provider.stream.add(response());
      await provider.stream.close();
      await request;
      final old = c.proposal!;
      if (action == 'listener') {
        c.addListener(() {
          if (c.busy) c.stop();
        });
      }
      final pending = c.revise(old, old.files);
      if (action == 'stop') c.stop();
      if (action == 'dispose') c.dispose();
      if (action == 'context') {
        records.values['studio.chat.v1.html-plan'] = 'changed';
      }
      if (action == 'deadline') await tester.pump(const Duration(seconds: 2));
      analysis.complete(report());
      await pending;
      expect(c.proposal, isNull);
      expect(c.busy, false);
      expect(() => c.authorizeProposal(old), throwsStateError);
      if (action != 'dispose') c.dispose();
    });
  }

  testWidgets(
    '320px 2x editor retains invalid draft, cancels and saves optional JS removal',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final provider = Provider();
      final c = HtmlSourceReviewController(
        project: seed.project,
        records: await seed.seed(),
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
        inspectReferences: (_) async => report(),
      );
      final request = c.request('Greeting');
      provider.stream.add(response());
      await provider.stream.close();
      await request;
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
      Future<void> tap(String text) async {
        await tester.scrollUntilVisible(
          find.text(text),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await Scrollable.ensureVisible(
          tester.element(find.text(text)),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(text));
        await tester.pumpAndSettle();
      }

      await tap('Edit reviewed source…');
      final editor = find.byType(HtmlSourceEditor);
      final fields = find.descendant(
        of: editor,
        matching: find.byType(TextField),
      );
      await tester.enterText(fields.at(0), '');
      await tap('Save edits for review');
      expect(c.error, contains('invalid'));
      expect(tester.widget<TextField>(fields.at(0)).controller!.text, '');
      await tester.enterText(fields.at(0), '<main>Edited</main>');
      await tester.enterText(fields.at(2), '');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.text('Save edits for review')),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save edits for review'));
      await tester.pumpAndSettle();
      expect(c.proposal!.files['index.html'], contains('Edited'));
      expect(c.proposal!.files.containsKey('app.js'), false);
      expect(c.locallyEdited, true);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('unapplied editor gates replacement and export', (tester) async {
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final provider = Provider();
    var calls = 0;
    final c = HtmlSourceReviewController(
      project: seed.project,
      records: await seed.seed(),
      proposer: HtmlSourceProposer(
        createProvider: (_) {
          calls++;
          return provider;
        },
      ),
      inspectReferences: (_) async => report(),
    );
    final request = c.request('Greeting');
    provider.stream.add(response());
    await provider.stream.close();
    await request;
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
    Future<void> reveal(String text, double delta) async {
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(text),
        delta,
        scrollable: find.byType(Scrollable).first,
      );
      await Scrollable.ensureVisible(
        tester.element(find.text(text)),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
    }

    await reveal('Edit reviewed source…', 200);
    await tester.tap(find.text('Edit reviewed source…'));
    await tester.pumpAndSettle();
    Finder field() => find
        .descendant(
          of: find.byType(HtmlSourceEditor),
          matching: find.byType(TextField),
        )
        .first;
    const dirty = '<main>Keep unapplied source exactly</main>';
    await tester.enterText(field(), dirty);
    await reveal('Export reviewed source…', 200);
    final export = find.widgetWithText(
      OutlinedButton,
      'Export reviewed source…',
    );
    expect(tester.widget<OutlinedButton>(export).onPressed, isNull);
    await tester.tap(find.text('Export reviewed source…'));
    await tester.pumpAndSettle();
    await reveal('Request source for review', -200);
    final replace = find.widgetWithText(
      FilledButton,
      'Request source for review',
    );
    expect(tester.widget<FilledButton>(replace).onPressed, isNull);
    await tester.tap(find.text('Request source for review'));
    await tester.pumpAndSettle();
    expect(calls, 1);
    expect(c.proposal, same(old));
    await reveal('Save edits for review', 200);
    expect(tester.widget<TextField>(field()).controller!.text, dirty);
    await reveal('Cancel edits', 200);
    await tester.tap(find.text('Cancel edits'));
    await tester.pumpAndSettle();
    expect(c.proposal, same(old));
    await reveal('Request source for review', -200);
    expect(tester.widget<FilledButton>(replace).onPressed, isNotNull);
    await reveal('Export reviewed source…', 200);
    expect(tester.widget<OutlinedButton>(export).onPressed, isNotNull);
    expect(find.byType(HtmlSourceEditor), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets(
    'failed inspection keeps editable draft; Cancel does not change source',
    (tester) async {
      final provider = Provider();
      var inspections = 0;
      final analysis = Completer<HtmlReferenceReport>();
      final c = HtmlSourceReviewController(
        project: seed.project,
        records: await seed.seed(),
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
        inspectReferences: (_) =>
            ++inspections == 2 ? analysis.future : Future.value(report()),
      );
      final request = c.request('Greeting');
      provider.stream.add(response());
      await provider.stream.close();
      await request;
      final old = c.proposal!;
      await tester.pumpWidget(
        MaterialApp(home: HtmlSourceReviewScreen(controller: c)),
      );
      Future<void> tap(String text, [double delta = 200]) async {
        FocusManager.instance.primaryFocus?.unfocus();
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text(text),
          delta,
          scrollable: find.byType(Scrollable).first,
        );
        await Scrollable.ensureVisible(
          tester.element(find.text(text)),
          alignment: 0.5,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text(text));
        await tester.pump();
      }

      await tap('Edit reviewed source…');
      Finder field() => find
          .descendant(
            of: find.byType(HtmlSourceEditor),
            matching: find.byType(TextField),
          )
          .first;
      await tester.enterText(field(), '<main>Cancelled draft</main>');
      await tap('Cancel edits');
      expect(c.proposal, same(old));
      c.authorizeProposal(old);
      await tap('Edit reviewed source…', -200);
      expect(
        tester.widget<TextField>(field()).controller!.text,
        old.files['index.html'],
      );
      await tester.enterText(field(), '<main>Retain this draft</main>');
      await tap('Save edits for review');
      expect(c.busy, true);
      expect(find.byType(HtmlSourceEditor), findsOneWidget);
      expect(
        tester.widget<TextField>(field()).controller!.text,
        contains('Retain this draft'),
      );
      analysis.completeError(StateError('private analysis error'));
      await tester.pumpAndSettle();
      expect(c.error, contains('inspection failed'));
      expect(c.proposal, isNull);
      await tap('Request source for review', -200);
      expect(
        tester
            .widget<FilledButton>(
              find.widgetWithText(FilledButton, 'Request source for review'),
            )
            .onPressed,
        isNull,
      );
      await tester.scrollUntilVisible(
        find.byType(HtmlSourceEditor),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        tester.widget<TextField>(field()).controller!.text,
        contains('Retain this draft'),
      );
      expect(() => c.authorizeProposal(old), throwsStateError);
      await tester.enterText(field(), '<main>Retry corrected draft</main>');
      await tap('Save edits for review');
      await tester.pumpAndSettle();
      expect(c.error, isNull);
      expect(
        c.proposal!.files['index.html'],
        '<main>Retry corrected draft</main>',
      );
      expect(c.proposal, isNot(same(old)));
      expect(find.byType(HtmlSourceEditor), findsNothing);
      expect(() => c.authorizeProposal(old), throwsStateError);
      c.authorizeProposal(c.proposal!);
      expect(inspections, 3);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  testWidgets('reviewer offscreen editor retains dirty source after focus loss', (
    tester,
  ) async {
    final provider = Provider();
    final c = HtmlSourceReviewController(
      project: seed.project,
      records: await seed.seed(),
      proposer: HtmlSourceProposer(createProvider: (_) => provider),
      inspectReferences: (_) async => HtmlReferenceReport(
        elements: 1,
        references: 0,
        findings: 0,
        messages: [],
      ),
    );
    final r = c.request('Greeting');
    provider.stream.add(
      jsonEncode({
        'summary': 'Long fixture',
        'files': {
          'index.html':
              '<main>${List.filled(1000, '<p>Greeting line</p>').join('\n')}</main>',
          'styles.css': 'main{color:navy}',
        },
      }),
    );
    await provider.stream.close();
    await r;
    await tester.pumpWidget(
      MaterialApp(home: HtmlSourceReviewScreen(controller: c)),
    );
    await tester.scrollUntilVisible(
      find.text('Edit reviewed source…'),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.ensureVisible(find.text('Edit reviewed source…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Edit reviewed source…'));
    await tester.pumpAndSettle();
    Finder field() => find
        .descendant(
          of: find.byType(HtmlSourceEditor),
          matching: find.byType(TextField),
        )
        .first;
    await tester.enterText(field(), '<main>Dirty retained editor</main>');
    await tester.scrollUntilVisible(
      find.text('Refine reviewed source'),
      -150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Refine reviewed source'),
          )
          .onPressed,
      isNull,
    );
    await tester.scrollUntilVisible(
      find.byType(HtmlSourceEditor),
      150,
      scrollable: find.byType(Scrollable).first,
    );

    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    final scrollable = tester.state<ScrollableState>(
      find.byType(Scrollable).first,
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    // Force traversal far beyond the editor's cache extent.
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await tester.pumpAndSettle();
    scrollable.position.jumpTo(0);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byType(HtmlSourceEditor),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester.widget<TextField>(field()).controller!.text,
      '<main>Dirty retained editor</main>',
    );
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'reviewer real workspace review route retains controller through theme change',
    (tester) async {
      final records = await seed.seed();
      late StateSetter theme;
      var dark = false;
      await tester.pumpWidget(
        StatefulBuilder(
          builder: (_, setState) {
            theme = setState;
            return MaterialApp(
              theme: ThemeData(
                brightness: dark ? Brightness.dark : Brightness.light,
              ),
              home: HtmlProjectWorkspace(
                project: seed.project,
                records: records,
              ),
            );
          },
        ),
      );
      final link = find.text('Review new HTML source');
      await tester.scrollUntilVisible(
        link,
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(link);
      await tester.pumpAndSettle();
      await tester.tap(link);
      await tester.pumpAndSettle();
      final original = tester
          .widget<HtmlSourceReviewScreen>(find.byType(HtmlSourceReviewScreen))
          .controller;
      theme(() => dark = true);
      await tester.pumpAndSettle();
      final next = tester
          .widget<HtmlSourceReviewScreen>(find.byType(HtmlSourceReviewScreen))
          .controller;
      expect(
        identical(original, next),
        true,
        reason: 'Route rebuild must retain review identity/listener/model ownership and editor authority',
      );
      tester.view.physicalSize = const Size(900, 700);
      addTearDown(tester.view.resetPhysicalSize);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<HtmlSourceReviewScreen>(find.byType(HtmlSourceReviewScreen))
            .controller,
        same(original),
      );
      expect(original.isDisposed, false);
      await tester.pageBack();
      await tester.pumpAndSettle();
      expect(original.isDisposed, true);
      await tester.pumpWidget(const SizedBox());
    },
  );
}
