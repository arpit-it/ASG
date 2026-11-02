// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:io';

import 'package:asg/controllers/html_export_controller.dart';
import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/dashboard.dart';
import 'package:asg/services/html/html_site_template.dart';
import 'package:asg/services/html/html_source_export.dart';
import 'package:asg/services/html/html_source_export_native.dart';
import 'package:asg/views/html_export_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Picker extends FolderPicker {
  _Picker(this.directory);
  final String directory;
  @override
  Future<String?> pick() async => directory;
}

class _Exporter implements HtmlSourceExport {
  int calls = 0;
  bool available = true;
  final entered = Completer<void>();
  final proceed = Completer<void>();
  Object? failure;
  @override
  bool get supported => available;
  @override
  Future<String> export({
    required HtmlExportRequest request,
    required HtmlExportRequest? confirmedRequest,
    required void Function() authorizeWrite,
  }) async {
    calls++;
    expect(identical(request, confirmedRequest), true);
    authorizeWrite();
    entered.complete();
    await proceed.future;
    authorizeWrite();
    if (failure != null) throw failure!;
    return '${request.parent}/${request.folderName}';
  }
}

Future<HtmlExportController> _ready(HtmlSourceExport exporter) async {
  final c = HtmlExportController(
    exporter: exporter,
    folderPicker: _Picker('/tmp'),
  );
  c.edit(title: 'A site', description: 'Useful content', folder: 'my_site');
  await c.pickParent();
  c.prepareReview();
  expect(c.review, isNotNull);
  return c;
}

class _Records implements RecordStorage {
  @override
  String? getString(String key) => null;
  @override
  Future<bool> setString(String key, String value) async =>
      throw StateError('Export must not register project records.');
}

void main() {
  test('native factory retains process ownership across screen reopening', () {
    expect(identical(createHtmlSourceExport(), createHtmlSourceExport()), true);
  });
  testWidgets('dashboard opens export flow without creating a project record', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Dashboard(
          store: StudioStore(_Records()),
          initialProjects: const [],
        ),
      ),
    );
    await tester.tap(find.text('Export HTML starter'));
    await tester.pumpAndSettle();
    expect(find.byType(HtmlExportScreen), findsOneWidget);
    // Lazy children need real scrolling on unsupported hosts and narrow layouts.
    await tester.scrollUntilVisible(
      find.text('Review export'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(find.text('Review export'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('unsupported host displays reason and refuses export controls', (
    tester,
  ) async {
    final c = HtmlExportController(exporter: _Exporter()..available = false);
    await tester.pumpWidget(MaterialApp(home: HtmlExportScreen(controller: c)));
    expect(
      find.text(
        'HTML source export requires macOS. This host is not supported.',
      ),
      findsOneWidget,
    );
    await tester.scrollUntilVisible(
      find.text('Review export'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    final review = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, 'Review export'),
    );
    expect(review.onPressed, isNull);
    expect(c.review, isNull);
  });

  test(
    'stale review cannot dispatch; duplicate confirm cannot replay',
    () async {
      final service = _Exporter();
      final c = await _ready(service);
      final stale = c.review!;
      c.edit(title: 'Changed');
      await c.confirm(stale);
      expect(service.calls, 0);
      c.prepareReview();
      final current = c.review!;
      final operation = c.confirm(current);
      await service.entered.future;
      await c.confirm(current);
      c.edit(title: 'Ignored while busy');
      expect(service.calls, 1);
      expect(c.review!.input.title, 'Changed');
      service.proceed.complete();
      await operation;
      expect(c.exportedDirectory, '/tmp/my_site');
      expect(c.review, isNull);
      await c.confirm(current);
      expect(service.calls, 1);
      c.dispose();
    },
  );
  for (final dispose in [false, true]) {
    test(
      '${dispose ? 'disposal' : 'Stop'} revokes authority at the next write boundary',
      () async {
        final service = _Exporter();
        final c = await _ready(service);
        var updates = 0;
        c.addListener(() => updates++);
        final operation = c.confirm(c.review!);
        await service.entered.future;
        if (dispose) {
          c.dispose();
        } else {
          c.stop();
          expect(c.busy, true);
        }
        final before = updates;
        service.proceed.complete();
        await operation;
        expect(c.exportedDirectory, isNull);
        expect(c.busy, false);
        expect(c.review, isNull);
        if (dispose) {
          expect(updates, before);
        } else {
          expect(c.error, contains('already-dispatched'));
          c.dispose();
        }
      },
    );
  }
  test(
    'partial destination and unconfirmed PID retained; fresh review required',
    () async {
      final service = _Exporter()
        ..failure = const HtmlExportFailure(
          '/tmp/my_site',
          pendingDirectoryProcessId: 123,
        );
      final c = await _ready(service);
      final review = c.review!;
      final operation = c.confirm(review);
      service.proceed.complete();
      await operation;
      expect(c.error, contains('/tmp/my_site'));
      expect(c.error, contains('123'));
      expect(c.exportedDirectory, isNull);
      expect(c.review, isNull);
      await c.confirm(review);
      expect(service.calls, 1);
      c.dispose();
    },
  );
  test(
    'unsupported host and invalid inputs cannot reach confirmation',
    () async {
      final service = _Exporter()..available = false;
      final c = HtmlExportController(exporter: service);
      c.prepareReview();
      expect(c.review, isNull);
      expect(c.error, contains('macOS'));
      service.available = true;
      c.edit(title: 'Title', description: 'Description', folder: '../old');
      c.prepareReview();
      expect(c.review, isNull);
      expect(service.calls, 0);
      c.dispose();
    },
  );
  testWidgets(
    'screen reviews exact inputs before real fixed-file export at 320px/2x',
    (tester) async {
      final temporary = (await tester.runAsync(() async {
        final folder = await Directory.systemTemp.createTemp('asg-html-ui-');
        return Directory(await folder.resolveSymbolicLinks());
      }))!;
      addTearDown(
        () => tester.runAsync(() => temporary.delete(recursive: true)),
      );
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = HtmlExportController(
        exporter: HtmlSourceExportNative(),
        folderPicker: _Picker(temporary.path),
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: HtmlExportScreen(controller: c),
        ),
      );
      for (final entry in {
        'Site title': 'My exported site',
        'Site description': 'Local source for editing',
        'New folder name': 'exported_site',
      }.entries) {
        final field = find.widgetWithText(TextField, entry.key);
        await tester.scrollUntilVisible(
          field,
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.enterText(field, entry.value);
        await tester.pumpAndSettle();
      }
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('Choose parent folder'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Choose parent folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose parent folder'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        expect(await temporary.list().toList(), isEmpty);
      });
      await tester.scrollUntilVisible(
        find.text('Review export'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Review export'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Review export'));
      await tester.pumpAndSettle();
      final review = c.review!;
      expect(review.parent, temporary.path);
      await tester.runAsync(() async {
        expect(await temporary.list().toList(), isEmpty);
      });
      await tester.scrollUntilVisible(
        find.text('Confirm and export files'),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Confirm and export files'));
      await tester.pumpAndSettle();
      await tester.runAsync(() async {
        await tester.tap(find.text('Confirm and export files'));
        for (var i = 0; i < 100 && c.busy; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(c.busy, false);
        expect(c.error, isNull);
        for (final entry in HtmlSiteTemplate().generate(review.input).entries) {
          expect(
            await File('${temporary.path}/exported_site/${entry.key}')
                .readAsString(),
            entry.value,
          );
        }
      });
      await tester.pumpAndSettle();
      expect(c.exportedDirectory, '${temporary.path}/exported_site');
      await tester.runAsync(c.checkExport);
      expect(c.sourceCheck?.files, 5);
      expect(c.checkError, isNull);
      await tester.drag(find.byType(Scrollable).first, const Offset(0, 10000));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(
          'Source export complete. HTML project creation remains planned.',
        ),
        180,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          'Source export complete. HTML project creation remains planned.',
        ),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      expect(c.isDisposed, true);
    },
    skip: !Platform.isMacOS,
  );
}
