// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/html_reviewed_export_controller.dart';
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
  Completer<HtmlReviewedSourceCheck> completion = Completer();
  @override
  Future<HtmlReviewedSourceCheck> check({
    required String directory,
    required HtmlSourceProposal proposal,
    required void Function() authorizeRead,
  }) {
    calls++;
    authorizeRead();
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
      if (action == 'dispose') {
        expect(updates, before);
      } else {
        c.dispose();
      }
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
