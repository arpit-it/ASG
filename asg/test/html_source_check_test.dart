// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/html_export_controller.dart';
import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/models/html/html_source_check.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/services/html/html_site_template.dart';
import 'package:asg/services/html/html_source_check.dart';
import 'package:asg/services/html/html_source_check_native.dart';
import 'package:asg/services/html/html_source_export.dart';
import 'package:asg/views/html_export_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Picker extends FolderPicker {
  @override
  Future<String?> pick() async => '/tmp';
}

class _Export implements HtmlSourceExport {
  @override
  bool get supported => true;
  @override
  Future<String> export({
    required HtmlExportRequest request,
    required HtmlExportRequest? confirmedRequest,
    required void Function() authorizeWrite,
  }) async {
    authorizeWrite();
    return '/tmp/site';
  }
}

class _Check implements HtmlSourceChecker {
  Completer<HtmlSourceCheck> completion = Completer();
  int calls = 0;
  bool available = true;
  @override
  bool get supported => available;
  @override
  Future<HtmlSourceCheck> check({
    required String directory,
    required HtmlSiteInput input,
    required void Function() authorizeRead,
  }) {
    expect(directory, '/tmp/site');
    expect(input.title, 'My site');
    calls++;
    authorizeRead();
    return completion.future;
  }
}

Future<HtmlExportController> _ready(_Check checker) async {
  final c = HtmlExportController(
    exporter: _Export(),
    sourceChecker: checker,
    folderPicker: _Picker(),
  );
  c.edit(title: 'My site', description: 'Description', folder: 'site');
  await c.pickParent();
  c.prepareReview();
  await c.confirm(c.review!);
  return c;
}

void main() {
  const result = HtmlSourceCheck(files: 5, bytes: 123);
  test(
    'check requires export and supported host, suppresses duplicate reads',
    () async {
      final checker = _Check();
      final c = HtmlExportController(
        exporter: _Export(),
        sourceChecker: checker,
      );
      await c.checkExport();
      expect(checker.calls, 0);
      c.dispose();
      final exported = await _ready(checker);
      checker.available = false;
      await exported.checkExport();
      expect(checker.calls, 0);
      checker.available = true;
      final pending = exported.checkExport();
      await exported.checkExport();
      expect(checker.calls, 1);
      expect(exported.checking, true);
      checker.completion.complete(result);
      await pending;
      expect(exported.sourceCheck, same(result));
      exported.edit(title: 'Changed');
      expect(exported.sourceCheck, isNull);
      expect(exported.exportedDirectory, isNull);
      exported.dispose();
    },
  );
  for (final action in ['Stop', 'edit', 'dispose']) {
    test('$action revokes late check success', () async {
      final checker = _Check();
      final c = await _ready(checker);
      final operation = c.checkExport();
      var updates = 0;
      c.addListener(() => updates++);
      if (action == 'Stop') c.stopCheck();
      if (action == 'edit') c.edit(title: 'Changed');
      if (action == 'dispose') c.dispose();
      final before = updates;
      checker.completion.complete(result);
      await operation;
      expect(c.sourceCheck, isNull);
      expect(c.checking, false);
      if (action == 'dispose') expect(updates, before);
      if (action != 'dispose') c.dispose();
    });
  }
  test('failed check retains source and supports explicit retry', () async {
    final checker = _Check();
    final c = await _ready(checker);
    final operation = c.checkExport();
    checker.completion.completeError(const FormatException('changed'));
    await operation;
    expect(c.checkError, contains('Nothing was changed'));
    expect(c.exportedDirectory, '/tmp/site');
    checker.completion = Completer();
    final retry = c.checkExport();
    checker.completion.complete(result);
    await retry;
    expect(c.checkError, isNull);
    expect(c.sourceCheck, same(result));
    c.dispose();
  });
  testWidgets(
    'deadline revokes late result and holds duplicate guard until IO settles',
    (tester) async {
      final checker = _Check();
      final c = await _ready(checker);
      final operation = c.checkExport();
      await tester.pump(const Duration(seconds: 10));
      expect(c.checkStopped, true);
      expect(c.checkError, contains('deadline'));
      await c.checkExport();
      expect(checker.calls, 1);
      checker.completion.complete(result);
      await operation;
      expect(c.sourceCheck, isNull);
      expect(c.checking, false);
      c.dispose();
    },
  );
  testWidgets(
    'narrow doubled-text Check and Stop are reachable with honest outcome',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final checker = _Check();
      final c = await _ready(checker);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: HtmlExportScreen(controller: c),
        ),
      );
      Future<void> reveal(String text) async {
        await tester.drag(
          find.byType(Scrollable).first,
          const Offset(0, 10000),
        );
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text(text),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
      }

      await reveal('Check exported files');
      await tester.tap(find.text('Check exported files'));
      await tester.pump();
      // The global Stop section can precede the export after layout changes.
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 10000));
      await tester.pump();
      // A busy progress indicator animates; avoid pumpAndSettle until stopped.
      await tester.scrollUntilVisible(
        find.text('Stop check'),
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Stop check'));
      checker.completion.complete(result);
      await tester.pumpAndSettle();
      expect(c.sourceCheck, isNull);
      checker.completion = Completer();
      await reveal('Check exported files');
      await tester.tap(find.text('Check exported files'));
      checker.completion.complete(result);
      await tester.pumpAndSettle();
      await reveal(result.summary);
      expect(find.text(result.summary), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'runner limits are readable at 320px and doubled text without IO',
    (tester) async {
      tester.view.physicalSize = const Size(320, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final checker = _Check();
      final c = HtmlExportController(
        exporter: _Export(),
        sourceChecker: checker,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: HtmlExportScreen(controller: c),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Runner capabilities'),
        160,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Runner capabilities'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Runner capabilities'));
      await tester.pumpAndSettle();
      for (final label in [
        'Source identity',
        'Resolve dependencies',
        'Compile',
        'Project tests',
        'Preview cleanup',
      ]) {
        await tester.scrollUntilVisible(
          find.text(label),
          160,
          scrollable: find.byType(Scrollable).first,
        );
        expect(find.text(label), findsOneWidget);
        expect(tester.takeException(), isNull);
      }
      expect(
        find.textContaining('Not implemented: No project test runner'),
        findsOneWidget,
      );
      expect(checker.calls, 0);
      expect(c.exportedDirectory, isNull);
      await tester.pumpWidget(const SizedBox());
      expect(c.isDisposed, true);
    },
  );

  testWidgets(
    'editing during pending check retains visible revoked-read progress',
    (tester) async {
      final checker = _Check();
      final c = await _ready(checker);
      await tester.pumpWidget(
        MaterialApp(home: HtmlExportScreen(controller: c)),
      );
      final operation = c.checkExport();
      await tester.pump();
      await tester.enterText(
        find.widgetWithText(TextField, 'Site title'),
        'Changed title',
      );
      await tester.pump();
      expect(c.exportedDirectory, isNull);
      expect(c.checking, true);
      expect(c.checkStopped, true);
      await tester.scrollUntilVisible(
        find.text('Waiting for prior source reads to settle…'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text('Waiting for prior source reads to settle…'),
        findsOneWidget,
      );
      expect(find.widgetWithText(OutlinedButton, 'Stop check'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.widgetWithText(OutlinedButton, 'Stop check'),
            )
            .onPressed,
        isNull,
      );
      checker.completion.complete(result);
      await operation;
      await tester.pumpAndSettle();
      expect(c.sourceCheck, isNull);
      expect(c.checking, false);
      expect(
        find.text('Waiting for prior source reads to settle…'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );
  test('actual native export identity check rejects changes, links and missing files', () async {
    final temp = await Directory.systemTemp.createTemp('asg-source-check-');
    final dir = Directory(await temp.resolveSymbolicLinks());
    addTearDown(() => dir.delete(recursive: true));
    final input = HtmlSiteInput(title: 'My site', description: 'Description');
    final sources = HtmlSiteTemplate().generate(input);
    for (final e in sources.entries) {
      final file = File('${dir.path}/${e.key}');
      await file.parent.create(recursive: true);
      await file.writeAsString(e.value);
    }
    final checker = NativeHtmlSourceChecker();
    Future<HtmlSourceCheck> run() =>
        checker.check(directory: dir.path, input: input, authorizeRead: () {});
    final checked = await run();
    expect(checked.files, 5);
    expect(
      checked.bytes,
      sources.values.fold<int>(0, (n, s) => n + utf8.encode(s).length),
    );
    final file = File('${dir.path}/app.js');
    await file.writeAsString('changed');
    await expectLater(run(), throwsFormatException);
    expect(await file.readAsString(), 'changed');
    await file.delete();
    await expectLater(run(), throwsFormatException);
    final original = File('${dir.path}/original');
    await original.writeAsString(sources['app.js']!);
    await Link(file.path).create(original.path);
    await expectLater(run(), throwsFormatException);
    await Link(file.path).delete();
    await file.writeAsString(sources['app.js']!);
    expect((await run()).files, 5);
    await expectLater(
      checker.check(
        directory: dir.path,
        input: input,
        authorizeRead: () => throw StateError('stopped'),
      ),
      throwsStateError,
    );
    expect(await file.readAsString(), sources['app.js']);
  }, skip: !Platform.isMacOS);
}
