// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/models/html/html_reference_report.dart';
import 'package:asg/models/html/html_source_proposal.dart';
import 'package:asg/services/html/html_preview_host_native.dart';
import 'package:asg/services/html/html_reference_inspector.dart';
import 'package:asg/services/html/html_reviewed_source_check_native.dart';
import 'package:asg/services/html/html_source_export_native.dart';
import 'package:asg/services/studio_database.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/views/html_source_editor.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'html_source_draft_test.dart' as drafts;

class _RealHttp extends HttpOverrides {}

const svg =
    '<svg xmlns="http://www.w3.org/2000/svg" width="80" height="40"><rect width="80" height="40" fill="green"/></svg>';
HtmlSourceProposal source({bool script = true, String image = svg}) =>
    HtmlSourceProposal.decode(
      jsonEncode({
        'summary': 'Local image',
        'files': {
          'index.html': '<!doctype html><html><head><title>Image</title></head><body><img src="image.svg" alt="Green rectangle"></body></html>',
          'styles.css': 'img { max-width: 100%; }',
          if (script) 'app.js': 'throw new Error("Never execute");',
          'image.svg': image,
        },
      }),
    );
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'optional root SVG with or without JavaScript retains strict bounds',
    () {
      for (final script in [true, false]) {
        expect(source(script: script).files['image.svg'], svg);
      }
      final files = source().files;
      for (final invalid in ['', ' ', '\u0000', 'é' * 32001, 'x' * 64001]) {
        expect(() => source(image: invalid), throwsFormatException);
      }
      for (final name in [
        '../image.svg',
        '/image.svg',
        'assets/image.svg',
        'IMAGE.SVG',
        'other.svg',
        'image.png',
      ]) {
        expect(
          () => HtmlSourceProposal.decode(
            jsonEncode({
              'summary': 'Invalid',
              'files': {
                for (final e in files.entries)
                  if (e.key != 'image.svg') e.key: e.value,
                name: svg,
              },
            }),
          ),
          throwsFormatException,
        );
      }
      expect(
        () => source(image: 'a' * 64000).files.clear(),
        throwsUnsupportedError,
      );
      expect(
        () => HtmlSourceProposal.decode(
          jsonEncode({
            'summary': 'Too large',
            'files': {
              ...files,
              'image.svg': 'a' * 64000,
              'styles.css': 'b' * 64000,
            },
          }),
        ),
        throwsFormatException,
      );
    },
  );
  test(
    'local image resolves with SVG internals explicitly unverified',
    () async {
      final result = await inspectHtmlReferences(source());
      expect(result.references, 1);
      expect(result.findings, 0);
      expect(HtmlReferenceReport.limitations, contains('SVG content'));
    },
  );
  test(
    'edited SVG survives explicit draft save and fresh restoration',
    () async {
      final r = await drafts.records();
      final c = await drafts.ready(r);
      final old = c.proposal!;
      await c.revise(old, source().files);
      expect(c.error, isNull);
      expect(c.proposal!.files['image.svg'], svg);
      expect(() => c.authorizeProposal(old), throwsStateError);
      await c.saveDraft();
      expect(c.error, isNull);
      c.dispose();
      final restored = drafts.controller(
        r,
        inspect: (_) async => drafts.report(),
      );
      addTearDown(restored.dispose);
      await restored.restoreDraft();
      expect(restored.proposal!.files['image.svg'], svg);
      expect(restored.locallyEdited, true);
    },
  );
  test('local SVG draft survives actual database close/reopen', () async {
    final temp = await Directory.systemTemp.createTemp('asg_svg_draft_');
    addTearDown(() => temp.delete(recursive: true));
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final databasePath = '${temp.path}/records.db';
    var db = await databaseFactoryIo.openDatabase(databasePath);
    var store = await StudioDatabase.migrate(db, preferences);
    for (final entry in (await drafts.records()).values.entries) {
      if (!entry.key.startsWith('studio.application.')) {
        await store.setString(entry.key, entry.value);
      }
    }
    final c = await drafts.ready(store);
    await c.revise(c.proposal!, source().files);
    await c.saveDraft();
    expect(c.error, isNull);
    c.dispose();
    await db.close();
    db = await databaseFactoryIo.openDatabase(databasePath);
    store = await StudioDatabase.migrate(db, preferences);
    try {
      final restored = drafts.controller(
        store,
        inspect: (_) async => drafts.report(),
      );
      try {
        await restored.restoreDraft();
        expect(restored.proposal!.files['image.svg'], svg);
        expect(restored.proposal!.files, source().files);
      } finally {
        restored.dispose();
      }
    } finally {
      await db.close();
    }
  });
  testWidgets('editor changes and explicitly removes optional SVG', (
    tester,
  ) async {
    Map<String, String>? saved;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HtmlSourceEditor(
              proposal: source(),
              onSave: (files) => saved = files,
              onCancel: () {},
            ),
          ),
        ),
      ),
    );
    final input = find.widgetWithText(TextField, 'image.svg (optional)');
    await tester.ensureVisible(input);
    await tester.enterText(input, svg.replaceFirst('green', 'blue'));
    final save = find.text('Save edits for review');
    await tester.ensureVisible(save);
    await tester.tap(save);
    expect(saved!['image.svg'], contains('blue'));
    expect(saved!['app.js'], source().files['app.js']);
    await tester.ensureVisible(input);
    await tester.enterText(input, '');
    await tester.ensureVisible(save);
    await tester.tap(save);
    expect(saved!.containsKey('image.svg'), false);
    await tester.pumpWidget(const SizedBox());
  });
  testWidgets(
    'actual export, exact SVG check and passive image request authority',
    (tester) async {
      await tester.runAsync(() async {
        final temp = await Directory.systemTemp.createTemp('asg_reviewed_svg_');
        final root = await temp.resolveSymbolicLinks();
        addTearDown(() => temp.delete(recursive: true));
        final proposal = source();
        final request = HtmlReviewedExportRequest(
          proposal: proposal,
          parent: root,
          folderName: 'with_image',
        );
        final directory = await HtmlSourceExportNative().exportReviewed(
          request: request,
          confirmedRequest: request,
          authorizeWrite: () {},
        );
        final checker = NativeHtmlReviewedSourceChecker();
        await checker.check(
          directory: directory,
          proposal: proposal,
          authorizeRead: () {},
        );
        expect(await File('$directory/image.svg').readAsString(), svg);
        final host = HtmlPreviewHostNative();
        addTearDown(host.stop);
        var fresh = true;
        final url = await host.startReviewed(
          directory: directory,
          proposal: proposal,
          authorizeRead: () {
            if (!fresh) throw StateError('Revoked');
          },
        );
        final client = HttpOverrides.runWithHttpOverrides(
          () => HttpClient(),
          _RealHttp(),
        );
        addTearDown(() => client.close(force: true));
        Future<HttpClientResponse> image({
          String dest = 'image',
          String mode = 'no-cors',
          String origin = 'null',
        }) async {
          final req = await client.getUrl(url.resolve('image.svg'));
          req.headers.set('sec-fetch-site', 'cross-site');
          req.headers.set('sec-fetch-dest', dest);
          req.headers.set('sec-fetch-mode', mode);
          req.headers.set('origin', origin);
          return req.close();
        }

        final response = await image();
        expect(response.statusCode, 200);
        expect(response.headers.contentType!.mimeType, 'image/svg+xml');
        expect(
          response.headers.value('content-security-policy'),
          contains("script-src 'none'"),
        );
        expect(await utf8.decoder.bind(response).join(), svg);
        for (final denied in [
          await image(dest: 'script'),
          await image(mode: 'cors'),
          await image(origin: 'https://foreign.invalid'),
        ]) {
          expect(denied.statusCode, 403);
          await denied.drain<void>();
        }
        await File('$directory/image.svg').writeAsString('changed');
        final snapshot = await image();
        expect(await utf8.decoder.bind(snapshot).join(), svg);
        fresh = false;
        final revoked = await image();
        expect(revoked.statusCode, 403);
        await revoked.drain<void>();
        await host.stop();
        expect(host.url, isNull);
        await expectLater(
          checker.check(
            directory: directory,
            proposal: proposal,
            authorizeRead: () {},
          ),
          throwsFormatException,
        );
      });
    },
    skip: !Platform.isMacOS,
  );
}
