// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/controllers/html_reviewed_export_controller.dart';
import 'package:asg/controllers/html_source_review_controller.dart';
import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/models/html/html_source_proposal.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/services/html/html_source_export.dart';
import 'package:asg/services/html/html_source_proposer.dart';
import 'package:asg/views/html_reviewed_export_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'html_planning_test.dart' as html;
import 'html_source_proposer_test.dart' show Provider;
import 'html_source_review_test.dart' show response;

class Picker extends FolderPicker {
  @override
  Future<String?> pick() async => '/tmp/parent';
}

class CountingPicker extends FolderPicker {
  int calls = 0;
  @override
  Future<String?> pick() async {
    calls++;
    return '/tmp/selected';
  }
}

class Exporter implements HtmlReviewedSourceExport {
  @override
  bool supported = true;
  int calls = 0;
  HtmlReviewedExportRequest? written;
  void Function()? authority;
  Completer<String>? pending;
  HtmlExportFailure? failure;
  @override
  Future<String> exportReviewed({
    required HtmlReviewedExportRequest request,
    required HtmlReviewedExportRequest? confirmedRequest,
    required void Function() authorizeWrite,
  }) async {
    calls++;
    expect(identical(request, confirmedRequest), true);
    authorizeWrite();
    written = request;
    authority = authorizeWrite;
    if (failure != null) throw failure!;
    return pending == null ? '/tmp/parent/site' : pending!.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Exporter exporter;
  late HtmlReviewedExportController c;
  late bool current;
  setUp(() {
    current = true;
    exporter = Exporter();
    c = HtmlReviewedExportController(
      proposal: HtmlSourceProposal.decode(response()),
      authorizeSource: () {
        if (!current) throw StateError('PRIVATE');
      },
      exporter: exporter,
      picker: Picker(),
    );
  });
  tearDown(() {
    if (!c.isDisposed) c.dispose();
  });
  Future<void> prepare() async {
    await c.pickParent();
    c.editFolder('site');
    c.prepareReview();
  }

  for (final boundary in [1, 2]) {
    test(
      'disposal inside selection authority at boundary $boundary revokes picker work',
      () async {
        c.dispose();
        final picker = CountingPicker();
        var calls = 0;
        c = HtmlReviewedExportController(
          proposal: HtmlSourceProposal.decode(response()),
          authorizeSource: () {
            if (++calls == boundary) c.dispose();
          },
          exporter: exporter,
          picker: picker,
        );
        await c.pickParent();
        expect(picker.calls, boundary == 1 ? 0 : 1);
        expect(c.parent, isEmpty);
        expect(c.picking, false);
        expect(c.review, isNull);
      },
    );
  }
  test(
    'disposal inside review authority cannot publish confirmation',
    () async {
      await prepare();
      final parent = c.parent;
      c.dispose();
      var revoke = false;
      c = HtmlReviewedExportController(
        proposal: HtmlSourceProposal.decode(response()),
        authorizeSource: () {
          if (revoke) c.dispose();
        },
        exporter: exporter,
        picker: Picker(),
      );
      await prepare();
      expect(c.parent, parent);
      revoke = true;
      c.prepareReview();
      expect(c.review, isNull);
      expect(c.parent, parent);
      expect(exporter.calls, 0);
    },
  );
  test(
    'only explicit exact review writes bytes; edits revoke old confirmation',
    () async {
      await prepare();
      final old = c.review!;
      c.editFolder('other');
      await c.confirm(old);
      expect(exporter.calls, 0);
      c.prepareReview();
      await c.confirm(c.review!);
      expect(exporter.written!.proposal.files, c.proposal.files);
      expect(exporter.written!.folderName, 'other');
      expect(c.destination, isNotNull);
      expect(c.review, isNull);
    },
  );
  test(
    'unsupported host, invalid folder and stale source refuse writes',
    () async {
      await c.pickParent();
      for (final value in ['', '../site', 'A', 's']) {
        c.editFolder(value);
        c.prepareReview();
        expect(c.review, isNull);
      }
      await prepare();
      current = false;
      await c.confirm(c.review!);
      expect(exporter.calls, 0);
      expect(c.error, isNot(contains('PRIVATE')));
      current = true;
      exporter.supported = false;
      c.prepareReview();
      expect(c.review, isNull);
    },
  );
  for (final action in ['stop', 'dispose', 'stale']) {
    test(
      '$action revokes pending writes and late success; overlap excluded',
      () async {
        await prepare();
        exporter.pending = Completer();
        final review = c.review!;
        final pending = c.confirm(review);
        await c.confirm(review);
        if (action == 'stop') c.stop();
        if (action == 'dispose') c.dispose();
        if (action == 'stale') current = false;
        expect(() => exporter.authority!(), throwsStateError);
        c.editFolder('other');
        await c.pickParent();
        c.prepareReview();
        expect(exporter.calls, 1);
        exporter.pending!.complete('/tmp/late');
        await pending;
        expect(c.destination, isNull);
        expect(c.busy, false);
      },
    );
  }
  test(
    'deadline waits for dispatched work; partial-path evidence retained',
    () async {
      c.dispose();
      c = HtmlReviewedExportController(
        proposal: HtmlSourceProposal.decode(response()),
        authorizeSource: () {},
        exporter: exporter,
        picker: Picker(),
        deadline: const Duration(milliseconds: 1),
      );
      await prepare();
      exporter.pending = Completer();
      final pending = c.confirm(c.review!);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(c.busy, true);
      expect(c.error, contains('deadline'));
      expect(() => exporter.authority!(), throwsStateError);
      exporter.pending!.completeError(
        const HtmlExportFailure('/tmp/partial', pendingDirectoryProcessId: 123),
      );
      await pending;
      expect(c.error, contains('/tmp/partial'));
      expect(c.error, contains('123'));
      expect(c.error, contains('deadline'));
      expect(c.destination, isNull);
    },
  );
  test('progress listener Stop prevents exporter dispatch', () async {
    await prepare();
    c.addListener(() {
      if (c.busy) c.stop();
    });
    await c.confirm(c.review!);
    expect(exporter.calls, 0);
  });
  for (final action in ['stop', 'dispose']) {
    for (final boundary in [1, 2, 3]) {
      test(
        '$action inside export authority at boundary $boundary revokes work',
        () async {
          c.dispose();
          var armed = false;
          var calls = 0;
          c = HtmlReviewedExportController(
            proposal: HtmlSourceProposal.decode(response()),
            authorizeSource: () {
              if (armed && ++calls == boundary) {
                if (action == 'stop') c.stop();
                if (action == 'dispose') c.dispose();
              }
            },
            exporter: exporter,
            picker: Picker(),
          );
          await prepare();
          armed = true;
          await c.confirm(c.review!);
          expect(exporter.calls, boundary == 1 ? 0 : 1);
          if (boundary <= 2) expect(exporter.written, isNull);
          expect(c.destination, isNull);
          expect(c.busy, false);
          if (action == 'stop') {
            armed = false;
            c.prepareReview();
            await c.confirm(c.review!);
            expect(c.destination, '/tmp/parent/site');
          }
        },
      );
    }
  }
  test(
    'source controller binds authority to current artifact and saved context',
    () async {
      final records = await html.seed();
      final provider = Provider();
      final source = HtmlSourceReviewController(
        project: html.project,
        records: records,
        proposer: HtmlSourceProposer(createProvider: (_) => provider),
      );
      addTearDown(source.dispose);
      final request = source.request('Greeting');
      provider.stream.add(response());
      await provider.stream.close();
      await request;
      final proposal = source.proposal!;
      source.authorizeProposal(proposal);
      expect(
        () => source.authorizeProposal(HtmlSourceProposal.decode(response())),
        throwsStateError,
      );
      records.values['studio.chat.v1.${html.project.id}'] = 'changed';
      expect(() => source.authorizeProposal(proposal), throwsStateError);
    },
  );
  testWidgets('320px 2x exact-source confirmation requires separate action', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 800);
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
        home: HtmlReviewedExportScreen(controller: c),
      ),
    );
    Future<void> reach(String text) async {
      await tester.scrollUntilVisible(
        find.text(text),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text(text));
      await tester.pumpAndSettle();
    }

    await reach('Choose export parent');
    await tester.tap(find.text('Choose export parent'));
    await tester.pumpAndSettle();
    await reach('New export folder');
    await tester.enterText(find.byType(TextField), 'site');
    FocusManager.instance.primaryFocus?.unfocus();
    await tester.pumpAndSettle();
    await reach('Review export destination and source');
    await tester.tap(find.text('Review export destination and source'));
    await tester.pumpAndSettle();
    expect(exporter.calls, 0);
    await reach('app.js');
    expect(find.text(c.proposal.files['app.js']!), findsOneWidget);
    await reach('Confirm untrusted source export');
    await tester.tap(find.text('Confirm untrusted source export'));
    await tester.pumpAndSettle();
    expect(exporter.calls, 1);
    expect(c.destination, '/tmp/parent/site');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    expect(c.isDisposed, true);
  });
}
