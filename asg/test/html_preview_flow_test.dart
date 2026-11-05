// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/controllers/html_export_controller.dart';
import 'package:asg/controllers/html_preview_controller.dart';
import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/models/html/saved_html_starter.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/services/html/html_preview.dart';
import 'package:asg/services/html/html_source_export_native.dart';
import 'package:asg/views/html_export_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RealHttp extends HttpOverrides {}

class _Preview implements HtmlPreview {
  final entered = Completer<void>();
  final result = Completer<Uri>();
  Completer<void>? opening;
  int starts = 0, stops = 0, opens = 0;
  bool failStop = false;
  Completer<void>? stopping;
  @override
  bool get supported => true;
  @override
  Future<Uri> start({
    required String directory,
    required HtmlSiteInput input,
    void Function()? authorizeRead,
  }) {
    starts++;
    if (!entered.isCompleted) entered.complete();
    return result.future;
  }

  @override
  Future<void> open() async {
    opens++;
    await opening?.future;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw StateError('cleanup');
    await stopping?.future;
  }
}

class _Picker extends FolderPicker {
  _Picker(this.parent);
  final String parent;
  @override
  Future<String?> pick() async => parent;
}

final _request = HtmlExportRequest(
  input: HtmlSiteInput(title: 'Preview & test', description: 'Local content'),
  parent: '/tmp',
  folderName: 'preview_site',
);
final _url = Uri.parse('http://127.0.0.1:12345/token/');

void main() {
  testWidgets('pending launch keeps visible Stop and cleanup ownership', (
    tester,
  ) async {
    final service = _Preview();
    final c = HtmlExportController(
      exporter: HtmlSourceExportNative(),
      previewService: service,
      savedStarter: SavedHtmlStarter(
        directory: '/tmp/preview_site',
        input: _request.input,
      ),
    );
    final start = c.startPreview();
    service.result.complete(_url);
    await start;
    await tester.pumpWidget(MaterialApp(home: HtmlExportScreen(controller: c)));
    service.opening = Completer<void>();
    final launch = c.preview.open();
    await tester.pump(const Duration(seconds: 11));
    expect(c.preview.url, isNull);
    await tester.scrollUntilVisible(
      find.text('Stop preview'),
      180,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pump();
    final stop = tester.widget<OutlinedButton>(
      find.widgetWithText(OutlinedButton, 'Stop preview'),
    );
    expect(stop.onPressed, isNotNull);
    service.stopping = Completer<void>();
    final cleanup = c.preview.stop();
    service.opening!.complete();
    await launch;
    expect(c.preview.opening, isFalse);
    expect(c.preview.stopping, isTrue);
    expect(c.preview.busy, isTrue);
    await c.startPreview();
    expect(service.starts, 1);
    service.stopping!.complete();
    await cleanup;
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets('browser deadline owns pending launch until settlement', (
    tester,
  ) async {
    final service = _Preview();
    final c = HtmlPreviewController(service);
    final start = c.start('/tmp/site', _request);
    service.result.complete(_url);
    await start;
    service.opening = Completer<void>();
    final launch = c.open();
    await tester.pump(const Duration(seconds: 11));
    expect(c.error, contains('Browser launch deadline'));
    expect(c.url, isNull);
    expect(c.opening, isTrue);
    expect(c.busy, isTrue);
    expect(service.stops, 1);
    await c.open();
    await c.start('/tmp/site', _request);
    expect(service.opens, 1);
    expect(service.starts, 1);
    service.opening!.complete();
    await launch;
    expect(c.busy, isFalse);
    expect(c.error, contains('launch request has returned'));
    expect(c.notice, isNot(contains('Browser launch requested')));
    await c.start('/tmp/site', _request);
    expect(service.starts, 2);
    c.dispose();
  });

  testWidgets('browser deadline retains failed cleanup for explicit retry', (
    tester,
  ) async {
    final service = _Preview();
    final c = HtmlPreviewController(service);
    final start = c.start('/tmp/site', _request);
    service.result.complete(_url);
    await start;
    service.opening = Completer<void>();
    service.failStop = true;
    final launch = c.open();
    await tester.pump(const Duration(seconds: 11));
    expect(c.cleanupFailed, isTrue);
    expect(c.error, contains('cleanup failed'));
    service.opening!.completeError(StateError('late launch failure'));
    await launch;
    expect(c.error, contains('cleanup failed'));
    await c.start('/tmp/site', _request);
    expect(service.starts, 1);
    service.failStop = false;
    await c.stop();
    expect(c.cleanupFailed, isFalse);
    c.dispose();
  });

  testWidgets('completed browser launch cancels deadline', (tester) async {
    final service = _Preview();
    final c = HtmlPreviewController(service);
    final start = c.start('/tmp/site', _request);
    service.result.complete(_url);
    await start;
    await c.open();
    await tester.pump(const Duration(seconds: 11));
    expect(c.url, _url);
    expect(c.notice, contains('Browser launch requested'));
    expect(c.error, isNull);
    expect(service.stops, 0);
    c.dispose();
  });
  for (final dispose in [false, true]) {
    test(
      '${dispose ? 'dispose' : 'Stop'} rejects late startup and duplicate start',
      () async {
        final service = _Preview();
        final c = HtmlPreviewController(service);
        var updates = 0;
        c.addListener(() => updates++);
        final operation = c.start('/tmp/preview_site', _request);
        await service.entered.future;
        await c.start('/tmp/preview_site', _request);
        expect(service.starts, 1);
        if (dispose) {
          c.dispose();
        } else {
          await c.stop();
        }
        final before = updates;
        service.result.complete(_url);
        await operation;
        expect(c.url, isNull);
        expect(service.stops, greaterThanOrEqualTo(2));
        if (dispose) {
          expect(updates, before);
        } else {
          c.dispose();
        }
      },
    );
  }
  test('startup failure is recoverable; cleanup failure prevents restart until Stop succeeds', () async {
    final service = _Preview();
    final c = HtmlPreviewController(service);
    final operation = c.start('/tmp/site', _request);
    service.result.completeError(StateError('changed files'));
    await operation;
    expect(c.error, contains('unchanged'));
    service.failStop = true;
    await c.stop();
    expect(c.cleanupFailed, true);
    await c.start('/tmp/site', _request);
    expect(service.starts, 1);
    service.failStop = false;
    await c.stop();
    expect(c.cleanupFailed, false);
    c.dispose();
  });
  testWidgets('startup deadline revokes host without publishing late URL', (
    tester,
  ) async {
    final service = _Preview();
    final c = HtmlPreviewController(service);
    final operation = c.start('/tmp/site', _request);
    await tester.pump(const Duration(seconds: 11));
    expect(service.stops, 1);
    expect(c.url, isNull);
    expect(c.busy, true); // pending IO is still owned, not falsely completed
    service.result.complete(_url);
    await operation;
    expect(c.url, isNull);
    expect(c.busy, false);
    c.dispose();
  });
  test(
    'late startup cleanup failure remains visible and blocks restart',
    () async {
      final service = _Preview();
      final c = HtmlPreviewController(service);
      final start = c.start('/tmp/site', _request);
      await c.stop();
      service.failStop = true;
      service.result.complete(_url);
      await start;
      expect(c.cleanupFailed, true);
      expect(c.error, contains('cleanup failed'));
      await c.start('/tmp/site', _request);
      expect(service.starts, 1);
      service.failStop = false;
      await c.stop();
      expect(c.cleanupFailed, false);
      c.dispose();
    },
  );
  test(
    'browser failure preserves URL; Stop prevents late launch success',
    () async {
      final service = _Preview();
      final c = HtmlPreviewController(service);
      final start = c.start('/tmp/site', _request);
      service.result.complete(_url);
      await start;
      service.opening = Completer<void>();
      final open = c.open();
      await c.open();
      expect(service.opens, 1);
      service.opening!.completeError(StateError('browser unavailable'));
      await open;
      expect(c.url, _url);
      expect(c.error, contains('Browser launch failed'));
      service.opening = Completer<void>();
      final late = c.open();
      await c.stop();
      service.opening!.complete();
      await late;
      expect(c.url, isNull);
      expect(c.notice, contains('Preview stopped'));
      c.dispose();
    },
  );

  testWidgets(
    'real export screen preview, Stop/retry, changed-source refusal and disposal at 320px/2x',
    (tester) async {
      final parent = (await tester.runAsync(() async {
        final d = await Directory.systemTemp.createTemp('asg-preview-flow-');
        return Directory(await d.resolveSymbolicLinks());
      }))!;
      addTearDown(() => tester.runAsync(() => parent.delete(recursive: true)));
      tester.view.physicalSize = const Size(320, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final c = HtmlExportController(
        exporter: HtmlSourceExportNative(),
        folderPicker: _Picker(parent.path),
      );
      c.edit(
        title: 'Preview & test',
        description: 'Local content',
        folder: 'preview_site',
      );
      await c.pickParent();
      c.prepareReview();
      await tester.runAsync(() => c.confirm(c.review!));
      expect(c.error, isNull);
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
      Future<void> tap(String label) async {
        await tester.scrollUntilVisible(
          find.text(label),
          180,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.runAsync(() async {
          await tester.tap(find.text(label));
          for (var i = 0; i < 100 && c.preview.busy; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 20));
          }
          expect(c.preview.busy, false);
        });
        await tester.pumpAndSettle();
      }

      await tap('Start preview');
      final url = c.preview.url!;
      final client = HttpOverrides.runWithHttpOverrides(
        () => HttpClient(),
        _RealHttp(),
      );
      addTearDown(() => client.close(force: true));
      await tester.runAsync(() async {
        final response = await (await client.getUrl(url)).close();
        expect(
          await utf8.decoder.bind(response).join(),
          contains('Preview &amp; test'),
        );
      });
      await tap('Stop preview');
      expect(c.preview.url, isNull);
      await tester.runAsync(() async {
        var refused = false;
        try {
          await (await client.getUrl(url)).close();
        } on SocketException {
          refused = true;
        }
        expect(refused, true);
      });
      await tap('Start preview');
      expect(c.preview.url, isNotNull);
      await tap('Stop preview');
      final scriptFile = File('${c.exportedDirectory}/app.js');
      final script = (await tester.runAsync(scriptFile.readAsString))!;
      await tester.runAsync(() => scriptFile.writeAsString('changed'));
      await tap('Start preview');
      expect(c.preview.url, isNull);
      expect(c.preview.error, contains('unchanged'));
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => scriptFile.writeAsString(script));
      await tap('Start preview');
      final disposedUrl = c.preview.url!;
      await tester.pumpWidget(const SizedBox());
      expect(c.preview.isDisposed, true);
      await tester.runAsync(() async {
        var refused = false;
        try {
          await (await client.getUrl(disposedUrl)).close();
        } on SocketException {
          refused = true;
        }
        expect(refused, true);
      });
    },
    skip: !Platform.isMacOS,
  );

  test('edit revokes active preview and successful export identity', () async {
    final parent = await Directory.systemTemp.createTemp('asg-preview-edit-');
    addTearDown(() => parent.delete(recursive: true));
    final service = _Preview();
    final c = HtmlExportController(
      exporter: HtmlSourceExportNative(),
      folderPicker: _Picker(await parent.resolveSymbolicLinks()),
      previewService: service,
    );
    c.edit(title: 'Title', description: 'Description', folder: 'preview_site');
    await c.pickParent();
    c.prepareReview();
    await c.confirm(c.review!);
    final start = c.startPreview();
    service.result.complete(_url);
    await start;
    expect(c.preview.url, _url);
    c.edit(title: 'Changed title');
    expect(c.exportedDirectory, isNull);
    expect(c.preview.url, isNull);
    await c.startPreview();
    expect(service.starts, 1);
    c.dispose();
  }, skip: !Platform.isMacOS);
}
