// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/html_reviewed_export_controller.dart';
import 'package:asg/controllers/html_source_review_controller.dart';
import 'package:asg/services/html/html_source_proposer.dart';
import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/models/html/html_source_proposal.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/services/html/html_reviewed_source_check.dart';
import 'package:asg/services/html/html_reviewed_source_check_native.dart';
import 'package:asg/services/html/html_reviewed_source_check_stub.dart';
import 'package:asg/services/html/html_source_export.dart';
import 'package:asg/views/html_reviewed_export_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'html_planning_test.dart' as html;
import 'html_source_proposer_test.dart' show Provider;
import 'html_source_review_test.dart' show response;
import 'html_source_draft_test.dart' show report;

HtmlSourceProposal source({bool script = true}) => HtmlSourceProposal.decode(
  jsonEncode({
    'summary': 'Untrusted source',
    'files': {
      'index.html': '<h1>庭園 🌱</h1>',
      'styles.css': 'body{}',
      if (script) 'app.js': 'throw Error("never execute");',
    },
  }),
);

class Picker extends FolderPicker {
  @override
  Future<String?> pick() async => '/exports';
}

class Export implements HtmlReviewedSourceExport {
  @override
  bool get supported => true;
  @override
  Future<String> exportReviewed({
    required HtmlReviewedExportRequest request,
    required HtmlReviewedExportRequest? confirmedRequest,
    required void Function() authorizeWrite,
  }) async {
    authorizeWrite();
    return '/exports/site';
  }
}

class Check implements HtmlReviewedSourceChecker {
  @override
  bool get supported => true;
  int calls = 0;
  int reads = 0;
  void Function()? authority;
  Completer<HtmlReviewedSourceCheck> completion = Completer();
  @override
  Future<HtmlReviewedSourceCheck> check({
    required String directory,
    required HtmlSourceProposal proposal,
    required void Function() authorizeRead,
  }) {
    calls++;
    authority = authorizeRead;
    authorizeRead();
    reads++;
    expect(directory, '/exports/site');
    return completion.future;
  }
}

Future<HtmlReviewedExportController> ready(
  Check check, {
  void Function()? authority,
}) async {
  final c = HtmlReviewedExportController(
    proposal: source(),
    authorizeSource: authority ?? () {},
    exporter: Export(),
    picker: Picker(),
    sourceChecker: check,
  );
  await c.checkExport();
  expect(check.calls, 0);
  await c.pickParent();
  c.editFolder('site');
  c.prepareReview();
  await c.confirm(c.review!);
  return c;
}

void main() {
  const result = HtmlReviewedSourceCheck(files: 3, bytes: 70);
  test('unsupported refuses before authority', () async {
    await expectLater(
      UnsupportedHtmlReviewedSourceChecker().check(
        directory: '/exports',
        proposal: source(),
        authorizeRead: () => fail('read'),
      ),
      throwsUnsupportedError,
    );
  });
  test('identity only, duplicate exclusion and edit invalidation', () async {
    final check = Check();
    final c = await ready(check);
    final pending = c.checkExport();
    await c.checkExport();
    c.editFolder('changed');
    await c.pickParent();
    c.prepareReview();
    expect(c.folder, 'site');
    expect(check.calls, 1);
    check.completion.complete(result);
    await pending;
    expect(c.sourceCheck, same(result));
    expect(
      c.sourceCheck!.summary,
      contains('No syntax, safety, browser or runtime'),
    );
    c.editFolder('changed');
    expect(c.sourceCheck, isNull);
    expect(c.destination, isNull);
    c.dispose();
  });
  for (final action in ['Stop', 'dispose', 'stale']) {
    test('$action suppresses late result', () async {
      final check = Check();
      var current = true;
      final c = await ready(
        check,
        authority: () {
          if (!current) throw StateError('stale');
        },
      );
      final pending = c.checkExport();
      var updates = 0;
      c.addListener(() => updates++);
      if (action == 'Stop') c.stopCheck();
      if (action == 'dispose') c.dispose();
      if (action == 'stale') current = false;
      final before = updates;
      await c.checkExport();
      expect(check.calls, 1);
      check.completion.complete(result);
      await pending;
      expect(c.sourceCheck, isNull);
      expect(c.destination, '/exports/site');
      if (action == 'Stop') {
        expect(c.checkError, contains('request has returned'));
        expect(c.checkError, isNot(contains('Waiting')));
      }
      if (action == 'dispose') {
        expect(updates, before);
      } else {
        c.dispose();
      }
    });
  }
  for (final action in ['stop', 'dispose']) {
    for (final boundary in [1, 2, 3]) {
      test(
        '$action inside identity authority boundary $boundary revokes reads',
        () async {
          final check = Check();
          var armed = false;
          var calls = 0;
          late HtmlReviewedExportController c;
          c = await ready(
            check,
            authority: () {
              if (armed && ++calls == boundary) {
                if (action == 'stop') c.stopCheck();
                if (action == 'dispose') c.dispose();
              }
            },
          );
          addTearDown(() {
            if (!c.isDisposed) c.dispose();
          });
          armed = true;
          final pending = c.checkExport();
          check.completion.complete(result);
          await pending;
          expect(check.calls, boundary == 1 ? 0 : 1);
          expect(check.reads, boundary <= 2 ? 0 : 1);
          expect(c.sourceCheck, isNull);
          expect(c.destination, '/exports/site');
          expect(c.checking, false);
          if (check.authority != null) {
            expect(check.authority!, throwsStateError);
          }
          if (action == 'stop') {
            armed = false;
            check.completion = Completer();
            final retry = c.checkExport();
            check.completion.complete(result);
            await retry;
            expect(c.sourceCheck, same(result));
            expect(c.checkError, isNull);
          }
        },
      );
    }
  }
  test('completed identity result loses current authority without losing destination', () async {
    final check = Check();
    var current = true;
    final c = await ready(
      check,
      authority: () {
        if (!current) throw StateError('private context');
      },
    );
    addTearDown(c.dispose);
    final pending = c.checkExport();
    check.completion.complete(result);
    await pending;
    expect(c.sourceCheck, same(result));
    current = false;
    expect(c.sourceCheck, isNull);
    expect(c.destination, '/exports/site');
  });
  testWidgets(
    'revoked completed evidence is hidden on refresh with recovery guidance',
    (tester) async {
      tester.view.physicalSize = const Size(1000, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final check = Check();
      var current = true;
      final c = await ready(
        check,
        authority: () {
          if (!current) throw StateError('private context');
        },
      );
      final pending = c.checkExport();
      check.completion.complete(result);
      await pending;
      await tester.pumpWidget(
        MaterialApp(home: HtmlReviewedExportScreen(controller: c)),
      );
      expect(find.text(result.summary), findsOneWidget);
      current = false;
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: HtmlReviewedExportScreen(controller: c),
        ),
      );
      await tester.pump();
      expect(find.text(result.summary), findsNothing);
      expect(find.textContaining('Source review changed.'), findsOneWidget);
      expect(
        find.text('Unverified source exported to: /exports/site'),
        findsOneWidget,
      );
      for (final label in [
        'Check reviewed file identity',
        'Review script-disabled preview',
      ]) {
        expect(
          tester
              .widget<OutlinedButton>(
                find.widgetWithText(OutlinedButton, label),
              )
              .onPressed,
          isNull,
        );
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
    },
  );
  for (final change in ['edit', 'context']) {
    test('completed check follows actual source $change authority', () async {
      final records = await html.seed();
      final provider = Provider();
      final review = HtmlSourceReviewController(
        project: html.project,
        records: records,
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
        inspectReferences: (_) async => report(),
      );
      addTearDown(review.dispose);
      final request = review.request('Greeting');
      provider.stream.add(response());
      await provider.stream.close();
      await request;
      final original = review.proposal!;
      final check = Check();
      final c = HtmlReviewedExportController(
        proposal: original,
        authorizeSource: () => review.authorizeProposal(original),
        exporter: Export(),
        picker: Picker(),
        sourceChecker: check,
      );
      addTearDown(c.dispose);
      await c.pickParent();
      c.editFolder('site');
      c.prepareReview();
      await c.confirm(c.review!);
      final pending = c.checkExport();
      check.completion.complete(result);
      await pending;
      expect(c.sourceCheck, same(result));
      if (change == 'edit') {
        await review.revise(original, {
          ...original.files,
          'styles.css': 'body { color: blue; }',
        });
        expect(review.proposal, isNotNull);
      } else {
        records.values['studio.chat.v1.${html.project.id}'] = 'changed';
      }
      expect(c.sourceCurrent, false);
      expect(c.sourceCheck, isNull);
      expect(c.destination, '/exports/site');
      await c.checkExport();
      expect(check.calls, 1);
      expect(c.checkError, isNot(contains('private')));
    });
  }
  test('failed check retains export, hides error and supports retry', () async {
    final check = Check();
    final c = await ready(check);
    final pending = c.checkExport();
    check.completion.completeError(const FormatException('private path'));
    await pending;
    expect(c.checkError, isNot(contains('private path')));
    expect(c.destination, '/exports/site');
    check.completion = Completer();
    final retry = c.checkExport();
    check.completion.complete(result);
    await retry;
    expect(c.checkError, isNull);
    expect(c.sourceCheck, same(result));
    c.dispose();
  });
  testWidgets('deadline retains IO guard and rejects late result', (
    tester,
  ) async {
    final check = Check();
    final c = await ready(check);
    final pending = c.checkExport();
    await tester.pump(const Duration(seconds: 10));
    expect(c.checkStopped, true);
    expect(c.checkError, contains('deadline'));
    await c.checkExport();
    expect(check.calls, 1);
    check.completion.complete(result);
    await pending;
    expect(c.sourceCheck, isNull);
    expect(c.checking, false);
    expect(c.checkError, contains('deadline'));
    expect(c.checkError, contains('request has returned'));
    expect(c.checkError, isNot(contains('Waiting')));
    c.dispose();
  });
  testWidgets('320px doubled text check and Stop reachable', (tester) async {
    tester.view.physicalSize = const Size(320, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final check = Check();
    final c = await ready(check);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: HtmlReviewedExportScreen(controller: c),
      ),
    );
    Future<void> reveal(String text) async {
      await tester.scrollUntilVisible(
        find.text(text),
        120,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text(text));
      await tester.pump();
    }

    await reveal('Check reviewed file identity');
    await tester.tap(find.text('Check reviewed file identity'));
    await tester.pump();
    await reveal('Stop identity check');
    await tester.tap(find.text('Stop identity check'));
    check.completion.complete(result);
    await tester.pumpAndSettle();
    expect(c.sourceCheck, isNull);
    check.completion = Completer();
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 10000));
    await tester.pumpAndSettle();
    await reveal('Check reviewed file identity');
    await tester.tap(find.text('Check reviewed file identity'));
    check.completion.complete(result);
    await tester.pumpAndSettle();
    await reveal(result.summary);
    expect(find.text(result.summary), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
  group('actual native IO', () {
    late Directory root;
    setUp(() async {
      final temp = await Directory.systemTemp.createTemp('asg-reviewed-check-');
      root = Directory(await temp.resolveSymbolicLinks());
    });
    tearDown(() => root.delete(recursive: true));
    for (final script in [true, false]) {
      test(
        'exact UTF8 script=$script; changes missing links extras refused',
        () async {
          final proposal = source(script: script);
          for (final e in proposal.files.entries) {
            await File('${root.path}/${e.key}').writeAsString(e.value);
          }
          final checker = NativeHtmlReviewedSourceChecker();
          Future<HtmlReviewedSourceCheck> check() => checker.check(
            directory: root.path,
            proposal: proposal,
            authorizeRead: () {},
          );
          final result = await check();
          expect(result.files, proposal.files.length);
          expect(
            result.bytes,
            proposal.files.values.fold<int>(
              0,
              (n, s) => n + utf8.encode(s).length,
            ),
          );
          final file = File('${root.path}/index.html');
          await file.writeAsString('changed');
          await expectLater(check(), throwsFormatException);
          expect(await file.readAsString(), 'changed');
          await file.delete();
          await expectLater(check(), throwsFormatException);
          await Link(file.path).create('/etc/hosts');
          await expectLater(check(), throwsFormatException);
          await Link(file.path).delete();
          await file.writeAsString(proposal.files['index.html']!);
          final extra = File('${root.path}/extra');
          await extra.writeAsString('retained');
          await expectLater(check(), throwsFormatException);
          expect(await extra.readAsString(), 'retained');
          await extra.delete();
          final alias = Link('${root.path}/alias');
          await alias.create(root.path);
          await expectLater(
            checker.check(
              directory: alias.path,
              proposal: proposal,
              authorizeRead: () {},
            ),
            throwsFormatException,
          );
          await alias.delete();
          await expectLater(
            checker.check(
              directory: root.path,
              proposal: proposal,
              authorizeRead: () => throw StateError('stopped'),
            ),
            throwsStateError,
          );
          expect((await check()).files, proposal.files.length);
        },
      );
    }
    test('revocation at later read boundary retains files', () async {
      final proposal = source();
      for (final e in proposal.files.entries) {
        await File('${root.path}/${e.key}').writeAsString(e.value);
      }
      var calls = 0;
      await expectLater(
        NativeHtmlReviewedSourceChecker().check(
          directory: root.path,
          proposal: proposal,
          authorizeRead: () {
            if (++calls == 12) throw StateError('stopped');
          },
        ),
        throwsStateError,
      );
      expect(calls, 12);
      expect(
        await File('${root.path}/index.html').readAsString(),
        proposal.files['index.html'],
      );
    });
  }, skip: !Platform.isMacOS);
}
