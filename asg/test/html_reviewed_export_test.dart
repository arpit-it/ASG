// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/models/html/html_source_proposal.dart';
import 'package:asg/services/html/html_source_export_native.dart';
import 'package:asg/services/html/html_source_export_stub.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

HtmlSourceProposal proposal({bool script = true, String title = '庭園 🌱'}) =>
    HtmlSourceProposal.decode(
      jsonEncode({
        'summary': 'Reviewed site',
        'files': {
          'index.html': '<!doctype html><title>$title</title><h1>$title</h1>',
          'styles.css': 'body { color: green; }\n',
          if (script)
            'app.js': 'throw new Error("Never execute during export");',
        },
      }),
    );
void main() {
  HtmlReviewedExportRequest request(
    String parent, {
    String folder = 'reviewed_site',
    HtmlSourceProposal? source,
  }) => HtmlReviewedExportRequest(
    proposal: source ?? proposal(),
    parent: parent,
    folderName: folder,
  );
  test('confirmation binds every reviewed byte and destination', () {
    final original = request('/exports');
    expect(original.matches(request('/exports')), true);
    for (final changed in [
      request('/elsewhere'),
      request('/exports', folder: 'different'),
      request('/exports', source: proposal(script: false)),
      request('/exports', source: proposal(title: 'Different')),
    ]) {
      expect(original.matches(changed), false);
    }
    expect(
      () => original.proposal.files['app.js'] = 'changed',
      throwsUnsupportedError,
    );
  });
  test('unsupported host refuses without requesting writes', () async {
    final exporter = UnsupportedHtmlReviewedSourceExport();
    expect(exporter.supported, false);
    final value = request('/exports');
    await expectLater(
      exporter.exportReviewed(
        request: value,
        confirmedRequest: value,
        authorizeWrite: () => fail('Unsupported writes'),
      ),
      throwsUnsupportedError,
    );
  });
  group('actual reviewed-source IO', () {
    late Directory root;
    late HtmlSourceExportNative exporter;
    setUp(() async {
      final temp = await Directory.systemTemp.createTemp(
        'asg_reviewed_export_',
      );
      root = Directory(await temp.resolveSymbolicLinks());
      exporter = HtmlSourceExportNative();
    });
    tearDown(() async => root.delete(recursive: true));
    test(
      'exports exact UTF-8 files with and without optional script',
      () async {
        final sentinel = File(path.join(root.path, 'original.html'));
        await sentinel.writeAsString('Original project');
        for (final script in [true, false]) {
          final value = request(
            root.path,
            folder: script ? 'with_script' : 'no_script',
            source: proposal(script: script),
          );
          final output = await exporter.exportReviewed(
            request: value,
            confirmedRequest: request(
              root.path,
              folder: value.folderName,
              source: proposal(script: script),
            ),
            authorizeWrite: () {},
          );
          expect(
            (await Directory(output).list().toList()).length,
            value.proposal.files.length,
          );
          for (final entry in value.proposal.files.entries) {
            expect(
              await File(path.join(output, entry.key)).readAsBytes(),
              utf8.encode(entry.value),
            );
          }
        }
        expect(await sentinel.readAsString(), 'Original project');
      },
    );
    test(
      'missing or changed confirmation and revoked authority create nothing',
      () async {
        final value = request(root.path);
        for (final confirmed in [
          null,
          request(root.path, source: proposal(title: 'Changed')),
        ]) {
          await expectLater(
            exporter.exportReviewed(
              request: value,
              confirmedRequest: confirmed,
              authorizeWrite: () {},
            ),
            throwsStateError,
          );
        }
        await expectLater(
          exporter.exportReviewed(
            request: value,
            confirmedRequest: value,
            authorizeWrite: () => throw StateError('Revoked'),
          ),
          throwsStateError,
        );
        expect(await root.list().toList(), isEmpty);
      },
    );
    test('existing paths and symbolic parents are preserved', () async {
      final value = request(root.path);
      final existing = File(path.join(root.path, value.folderName));
      await existing.writeAsString('Retain');
      await expectLater(
        exporter.exportReviewed(
          request: value,
          confirmedRequest: value,
          authorizeWrite: () {},
        ),
        throwsStateError,
      );
      expect(await existing.readAsString(), 'Retain');
      final link = Link(path.join(root.path, 'alias'));
      await link.create(root.path);
      final symbolic = request(link.path);
      await expectLater(
        exporter.exportReviewed(
          request: symbolic,
          confirmedRequest: symbolic,
          authorizeWrite: () {},
        ),
        throwsFormatException,
      );
      expect(await root.list().length, 2);
    });
    test('traversal is refused before folder creation', () async {
      final value = request(root.path, folder: '../escape');
      await expectLater(
        exporter.exportReviewed(
          request: value,
          confirmedRequest: value,
          authorizeWrite: () {},
        ),
        throwsFormatException,
      );
      expect(await root.list().toList(), isEmpty);
    });
    test(
      'revocation after folder creation reports retained partial location',
      () async {
        final value = request(root.path);
        final destination = path.join(root.path, value.folderName);
        await expectLater(
          exporter.exportReviewed(
            request: value,
            confirmedRequest: value,
            authorizeWrite: () {
              if (Directory(destination).existsSync()) {
                throw StateError('Stopped');
              }
            },
          ),
          throwsA(
            isA<HtmlExportFailure>().having(
              (f) => f.directory,
              'destination',
              destination,
            ),
          ),
        );
        expect(await Directory(destination).list().toList(), isEmpty);
      },
    );
    test(
      'revocation after file creation prevents content and later files',
      () async {
        final value = request(root.path);
        final destination = path.join(root.path, value.folderName);
        final index = File(path.join(destination, 'index.html'));
        await expectLater(
          exporter.exportReviewed(
            request: value,
            confirmedRequest: value,
            authorizeWrite: () {
              if (index.existsSync()) throw StateError('Stopped');
            },
          ),
          throwsA(isA<HtmlExportFailure>()),
        );
        expect(await index.length(), 0);
        expect(
          await File(path.join(destination, 'styles.css')).exists(),
          false,
        );
      },
    );
  }, skip: !Platform.isMacOS ? 'Actual native export requires macOS.' : false);
}
