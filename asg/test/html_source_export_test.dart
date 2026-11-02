// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/services/html/html_site_template.dart';
import 'package:asg/services/html/html_source_export_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as path;

void main() {
  HtmlExportRequest request(
    String parent, {
    String title = 'Local garden',
    String description = 'Grow together.',
    String name = 'garden_site',
  }) => HtmlExportRequest(
    input: HtmlSiteInput(title: title, description: description),
    parent: parent,
    folderName: name,
  );

  test('confirmation binds both normalized text fields and destination', () {
    final original = request('/exports');
    expect(
      original.matches(request('/exports', title: ' Local garden ')),
      true,
    );
    for (final changed in [
      request('/other'),
      request('/exports', name: 'other_site'),
      request('/exports', title: 'Changed'),
      request('/exports', description: 'Changed'),
    ]) {
      expect(original.matches(changed), false);
    }
  });

  group(
    'actual native export',
    () {
      late Directory temporary;
      late HtmlSourceExportNative exporter;
      setUp(() async {
        temporary = await Directory.systemTemp.createTemp('asg_html_export_');
        temporary = Directory(await temporary.resolveSymbolicLinks());
        exporter = HtmlSourceExportNative();
      });
      tearDown(() async => temporary.delete(recursive: true));

      test('writes exactly the five independent editable sources', () async {
        final plan = request(temporary.path, title: '<Garden>');
        final output = await exporter.export(
          request: plan,
          confirmedRequest: request(temporary.path, title: '<Garden>'),
          authorizeWrite: () {},
        );
        final actual = <String, String>{};
        await for (final file in Directory(output).list(recursive: true)) {
          if (file is File) {
            actual[path.relative(file.path, from: output)] = await file
                .readAsString();
          }
        }
        expect(actual, HtmlSiteTemplate().generate(plan.input));
        expect(actual['index.html'], contains('&lt;Garden&gt;'));
      });

      test('unconfirmed, stale or revoked requests create nothing', () async {
        final plan = request(temporary.path);
        for (final confirmation in [
          null,
          request(temporary.path, title: 'Changed'),
        ]) {
          await expectLater(
            exporter.export(
              request: plan,
              confirmedRequest: confirmation,
              authorizeWrite: () {},
            ),
            throwsStateError,
          );
        }
        await expectLater(
          exporter.export(
            request: plan,
            confirmedRequest: plan,
            authorizeWrite: () => throw StateError('Revoked'),
          ),
          throwsStateError,
        );
        expect(await temporary.list().toList(), isEmpty);
      });

      test('invalid folders and symbolic parents create nothing', () async {
        for (final name in [
          '../outside',
          'a/b',
          '/tmp/escape',
          'bad name',
          'ab',
        ]) {
          final plan = request(temporary.path, name: name);
          await expectLater(
            exporter.export(
              request: plan,
              confirmedRequest: plan,
              authorizeWrite: () {},
            ),
            throwsFormatException,
          );
        }
        final link = Link(path.join(temporary.path, 'alias'));
        await link.create(temporary.path);
        final plan = request(link.path);
        await expectLater(
          exporter.export(
            request: plan,
            confirmedRequest: plan,
            authorizeWrite: () {},
          ),
          throwsFormatException,
        );
        expect(await temporary.list().length, 1);
      });

      test(
        'existing file, directory and symbolic destination stay intact',
        () async {
          final plan = request(temporary.path);
          final destination = path.join(temporary.path, plan.folderName);
          final existing = File(destination);
          await existing.writeAsString('retain');
          Future<void> refused() => expectLater(
            exporter.export(
              request: plan,
              confirmedRequest: plan,
              authorizeWrite: () {},
            ),
            throwsStateError,
          );
          await refused();
          expect(await existing.readAsString(), 'retain');
          await existing.delete();
          await Directory(destination).create();
          final sentinel = File(path.join(destination, 'user.txt'));
          await sentinel.writeAsString('retain');
          await refused();
          expect(await sentinel.readAsString(), 'retain');
          await Directory(destination).delete(recursive: true);
          final link = Link(destination);
          await link.create(path.join(temporary.path, 'missing'));
          await refused();
          expect(await link.target(), path.join(temporary.path, 'missing'));
        },
      );

      test(
        'revocation after folder creation retains precise partial location',
        () async {
          final plan = request(temporary.path);
          final destination = path.join(temporary.path, plan.folderName);
          await expectLater(
            exporter.export(
              request: plan,
              confirmedRequest: plan,
              authorizeWrite: () {
                if (Directory(destination).existsSync()) {
                  throw StateError('Stopped');
                }
              },
            ),
            throwsA(
              isA<HtmlExportFailure>().having(
                (failure) => failure.directory,
                'partial directory',
                destination,
              ),
            ),
          );
          expect(await Directory(destination).exists(), true);
          expect(await Directory(destination).list().toList(), isEmpty);
        },
      );

      test(
        'revocation after first file prevents content and later writes',
        () async {
          final plan = request(temporary.path);
          final destination = path.join(temporary.path, plan.folderName);
          final index = File(path.join(destination, 'index.html'));
          await expectLater(
            exporter.export(
              request: plan,
              confirmedRequest: plan,
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
          expect(await Directory(destination).exists(), true);
        },
      );
      test('concurrent exports cannot replace the winning folder', () async {
        final plan = request(temporary.path);
        final results = await Future.wait(
          List.generate(2, (_) async {
            try {
              return await exporter.export(
                request: plan,
                confirmedRequest: plan,
                authorizeWrite: () {},
              );
            } catch (error) {
              return error;
            }
          }),
        );
        expect(results.whereType<String>().length, 1);
        expect(results.whereType<StateError>().length, 1);
        final directory = results.whereType<String>().single;
        for (final entry in HtmlSiteTemplate().generate(plan.input).entries) {
          expect(
            await File(path.join(directory, entry.key)).readAsString(),
            entry.value,
          );
        }
      });
    },
    skip: !Platform.isMacOS
        ? 'Native HTML export is Mac-verifiable only.'
        : false,
  );
}
