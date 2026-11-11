// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/models/html/html_source_proposal.dart';
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

      test('both export modes refuse bundle parents before dispatch', () async {
        final bundle = Directory(path.join(temporary.path, 'Synthetic.ApP'));
        final resources = await Directory(
          path.join(bundle.path, 'Contents', 'Resources'),
        ).create(recursive: true);
        final sentinel = File(path.join(resources.path, 'original.txt'));
        await sentinel.writeAsString('keep this content');

        final dispatches = <String>[];
        final recordingExporter = HtmlSourceExportNative(
          startDirectoryProcess: (directory) {
            dispatches.add(directory);
            return Process.start('/bin/mkdir', ['-m', '700', directory]);
          },
        );
        final proposal = HtmlSourceProposal.decode(
          jsonEncode({
            'summary': 'Reviewed export fixture',
            'files': {
              'index.html': '<!doctype html><title>Reviewed</title>',
              'styles.css': 'body { color: black; }',
            },
          }),
        );
        Future<String> fixed(String parent) {
          final plan = request(parent);
          return recordingExporter.export(
            request: plan,
            confirmedRequest: plan,
            authorizeWrite: () {},
          );
        }

        Future<String> reviewed(String parent) {
          final plan = HtmlReviewedExportRequest(
            proposal: proposal,
            parent: parent,
            folderName: 'reviewed_site',
          );
          return recordingExporter.exportReviewed(
            request: plan,
            confirmedRequest: plan,
            authorizeWrite: () {},
          );
        }

        for (final parent in [bundle.path, resources.path]) {
          await expectLater(fixed(parent), throwsFormatException);
          await expectLater(reviewed(parent), throwsFormatException);
        }
        expect(dispatches, isEmpty);
        expect(await sentinel.readAsString(), 'keep this content');
        expect(await resources.list().map((entry) => entry.path).toList(), [
          sentinel.path,
        ]);
        expect(await bundle.list().map((entry) => entry.path).toList(), [
          path.join(bundle.path, 'Contents'),
        ]);

        final external = await Directory(
          path.join(temporary.path, 'example.app-assets'),
        ).create();
        for (final export in [fixed, reviewed]) {
          final output = await export(external.path);
          expect(path.dirname(output), external.path);
          expect(await File(path.join(output, 'index.html')).exists(), isTrue);
        }
        expect(dispatches, hasLength(2));
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
      test('directory deadline kills and reaps the owned helper before failure', () async {
        final plan = request(temporary.path);
        final destination = path.join(temporary.path, plan.folderName);
        Process? helper;
        final stalled = HtmlSourceExportNative(
          startDirectoryProcess: (directory) async {
            helper = await Process.start('python3', [
              '-I',
              '-B',
              '-c',
              'import os,sys,time; time.sleep(30); os.mkdir(sys.argv[1])',
              directory,
            ]);
            return helper!;
          },
        );
        final watch = Stopwatch()..start();
        try {
          await expectLater(
            stalled.export(
              request: plan,
              confirmedRequest: plan,
              authorizeWrite: () {},
            ),
            throwsA(
              isA<HtmlExportFailure>()
                  .having(
                    (failure) => failure.directory,
                    'uncertain location',
                    destination,
                  )
                  .having(
                    (failure) => failure.pendingDirectoryProcessId,
                    'reaped child',
                    isNull,
                  ),
            ),
          );
          expect(watch.elapsed, lessThan(const Duration(seconds: 10)));
          expect(await helper!.exitCode, isNot(0));
          expect(stalled.pendingDirectoryProcessIds, isEmpty);
          expect(await Directory(destination).exists(), false);
          // Successful retry uses a new explicit service request after cleanup,
          // never an automatic replay of the stalled dispatch.
          expect(
            await exporter.export(
              request: plan,
              confirmedRequest: plan,
              authorizeWrite: () {},
            ),
            destination,
          );
        } finally {
          helper?.kill(ProcessSignal.sigkill);
          await helper?.exitCode;
        }
      });

      test(
        'directory dispatch failure reports its destination without writes',
        () async {
          final plan = request(temporary.path);
          final failed = HtmlSourceExportNative(
            startDirectoryProcess: (_) async {
              throw ProcessException('/bin/mkdir', [], 'launch failed');
            },
          );
          await expectLater(
            failed.export(
              request: plan,
              confirmedRequest: plan,
              authorizeWrite: () {},
            ),
            throwsA(
              isA<HtmlExportFailure>().having(
                (failure) => failure.directory,
                'uncertain location',
                path.join(temporary.path, plan.folderName),
              ),
            ),
          );
          expect(await temporary.list().toList(), isEmpty);
        },
      );

      test(
        'unconfirmed child exit blocks replay until reconciliation',
        () async {
          final plan = request(temporary.path);
          final child = _UnconfirmedDirectoryProcess();
          var dispatches = 0;
          final stalled = HtmlSourceExportNative(
            startDirectoryProcess: (_) async {
              dispatches++;
              return child;
            },
          );
          try {
            await expectLater(
              stalled.export(
                request: plan,
                confirmedRequest: plan,
                authorizeWrite: () {},
              ),
              throwsA(
                isA<HtmlExportFailure>().having(
                  (failure) => failure.pendingDirectoryProcessId,
                  'pending child',
                  child.pid,
                ),
              ),
            );
            expect(child.killRequested, true);
            expect(stalled.pendingDirectoryProcessIds, [child.pid]);
            await expectLater(
              stalled.export(
                request: plan,
                confirmedRequest: plan,
                authorizeWrite: () {},
              ),
              throwsStateError,
            );
            expect(dispatches, 1);
            expect(await temporary.list().toList(), isEmpty);
          } finally {
            child.exited.complete(-9);
            await Future<void>.delayed(Duration.zero);
          }
          expect(stalled.pendingDirectoryProcessIds, isEmpty);
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

// Models an OS child whose termination was requested but exit is not observed.
// The actual helper deadline regression above separately proves real cleanup.
class _UnconfirmedDirectoryProcess implements Process {
  final exited = Completer<int>();
  bool killRequested = false;
  @override
  int get pid => 424242;
  @override
  Future<int> get exitCode => exited.future;
  @override
  Stream<List<int>> get stdout => Stream.error(StateError('capture failed'));
  @override
  Stream<List<int>> get stderr => const Stream.empty();
  @override
  IOSink get stdin => throw UnsupportedError('No input for mkdir.');
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    killRequested = true;
    return true;
  }
}
