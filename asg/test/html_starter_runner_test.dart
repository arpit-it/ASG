// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/html/html_runner_result.dart';
import 'package:asg/models/html/html_site_input.dart';
import 'package:asg/models/html/html_source_check.dart';
import 'package:asg/models/project_runner.dart';
import 'package:asg/services/html/html_preview.dart';
import 'package:asg/services/html/html_source_check.dart';
import 'package:asg/services/html/html_source_export_native.dart';
import 'package:asg/models/html/html_export_request.dart';
import 'package:asg/services/html/html_starter_runner.dart';
import 'package:asg/services/project_runner_registry.dart';
import 'package:flutter_test/flutter_test.dart';

class _Checker implements HtmlSourceChecker {
  bool available = true;
  int calls = 0;
  Completer<HtmlSourceCheck>? pending;
  @override
  bool get supported => available;
  @override
  Future<HtmlSourceCheck> check({
    required String directory,
    required HtmlSiteInput input,
    required void Function() authorizeRead,
  }) async {
    calls++;
    return pending == null
        ? const HtmlSourceCheck(files: 5, bytes: 123)
        : await pending!.future;
  }
}

class _Preview implements HtmlPreview {
  bool available = true;
  int starts = 0, opens = 0, stops = 0;
  Completer<Uri>? pending;
  void Function()? authority;
  bool failStop = false;
  @override
  bool get supported => available;
  @override
  Future<Uri> start({
    required String directory,
    required HtmlSiteInput input,
    void Function()? authorizeRead,
  }) async {
    starts++;
    authority = authorizeRead;
    return pending == null
        ? Uri.parse('http://127.0.0.1:1234/token/')
        : await pending!.future;
  }

  @override
  Future<void> open() async {
    opens++;
  }

  @override
  Future<void> stop() async {
    stops++;
    if (failStop) throw StateError('cleanup failed');
  }
}

void main() {
  final input = HtmlSiteInput(
    title: 'Runner site',
    description: 'Local starter',
  );
  test(
    'discovery has no side effects; unknown and legacy stacks are unregistered',
    () {
      final checker = _Checker();
      final preview = _Preview();
      final runner = HtmlStarterRunner(checker: checker, preview: preview);
      final registry = ProjectRunnerRegistry(html: runner);
      final descriptor = registry.discover('HTML')!;
      expect(descriptor.id, 'asg-fixed-html');
      expect(descriptor.version, '1.0.0');
      expect(descriptor.adapterId, 'asg-static-html-v1');
      expect(
        descriptor.operations.keys.toSet(),
        RunnerOperation.values.toSet(),
      );
      expect(() => descriptor.operations.clear(), throwsUnsupportedError);
      for (final stack in ['Python', 'Flutter', 'html', 'unknown']) {
        expect(registry.discover(stack), isNull);
        expect(registry.htmlRunner(stack), isNull);
      }
      expect(registry.htmlRunner('HTML'), same(runner));
      expect(checker.calls + preview.starts + preview.opens + preview.stops, 0);
    },
  );
  test('inapplicable and undelivered operations never return completed or dispatch', () async {
    final checker = _Checker();
    final preview = _Preview();
    final runner = HtmlStarterRunner(checker: checker, preview: preview);
    for (final operation in [
      RunnerOperation.resolveDependencies,
      RunnerOperation.compile,
      RunnerOperation.test,
    ]) {
      final result = await runner.execute(operation);
      expect(result.status, RunnerResultStatus.unsupported);
      expect(result.operation, operation);
      expect(result.sourceCheck, isNull);
      expect(result.previewUrl, isNull);
      expect(result.detail, isNotEmpty);
    }
    expect(
      runner.descriptor.capability(RunnerOperation.test).availability,
      RunnerAvailability.notImplemented,
    );
    expect(checker.calls + preview.starts + preview.opens + preview.stops, 0);
  });
  test(
    'host capabilities match dispatch, and cleanup is always available',
    () async {
      final checker = _Checker()..available = false;
      final preview = _Preview()..available = false;
      final runner = HtmlStarterRunner(checker: checker, preview: preview);
      for (final operation in [
        RunnerOperation.checkSources,
        RunnerOperation.run,
        RunnerOperation.open,
      ]) {
        expect(
          runner.descriptor.capability(operation).availability,
          RunnerAvailability.unavailableHost,
        );
        expect(
          (await runner.execute(operation)).status,
          RunnerResultStatus.unsupported,
        );
      }
      expect(checker.calls + preview.starts + preview.opens, 0);
      await runner.stop();
      expect(preview.stops, 1);
      checker.available = true;
      expect(
        runner.descriptor.capability(RunnerOperation.checkSources).canDispatch,
        true,
      );
      expect(runner.supported, false);
      expect(
        (await runner.checkSources(
          directory: '/tmp/site',
          input: input,
          authorizeRead: () {},
        )).files,
        5,
      );
    },
  );
  test('required inputs and revoked read authority prevent dispatch and late success', () async {
    final checker = _Checker();
    final preview = _Preview();
    final runner = HtmlStarterRunner(checker: checker, preview: preview);
    for (final operation in [
      RunnerOperation.checkSources,
      RunnerOperation.run,
    ]) {
      await expectLater(runner.execute(operation), throwsArgumentError);
    }
    await expectLater(
      runner.checkSources(
        directory: '/tmp/site',
        input: input,
        authorizeRead: () => throw StateError('revoked'),
      ),
      throwsStateError,
    );
    expect(checker.calls, 0);
    checker.pending = Completer();
    var authorized = true;
    final check = runner.checkSources(
      directory: '/tmp/site',
      input: input,
      authorizeRead: () {
        if (!authorized) throw StateError('revoked');
      },
    );
    authorized = false;
    checker.pending!.complete(const HtmlSourceCheck(files: 5, bytes: 123));
    await expectLater(check, throwsStateError);
    expect(preview.starts, 0);
  });
  test(
    'preview interface dispatches through the same runner contract',
    () async {
      final preview = _Preview();
      final runner = HtmlStarterRunner(checker: _Checker(), preview: preview);
      expect(
        (await runner.start(directory: '/tmp/site', input: input)).port,
        1234,
      );
      await runner.open();
      await runner.stop();
      expect([preview.starts, preview.opens, preview.stops], [1, 1, 1]);
    },
  );
  test(
    'preview authority refuses dispatch and is forwarded unchanged',
    () async {
      final preview = _Preview();
      final runner = HtmlStarterRunner(preview: preview);
      await expectLater(
        runner.start(
          directory: '/tmp/site',
          input: input,
          authorizeRead: () => throw StateError('revoked'),
        ),
        throwsStateError,
      );
      expect(preview.starts, 0);
      var allowed = true;
      void authorize() {
        if (!allowed) throw StateError('revoked');
      }

      await runner.start(
        directory: '/tmp/site',
        input: input,
        authorizeRead: authorize,
      );
      expect(preview.authority, same(authorize));
      allowed = false;
      expect(preview.authority!, throwsStateError);
      await runner.stop();
    },
  );
  for (final failCleanup in [false, true]) {
    test(
      'late preview revocation retains cleanup result $failCleanup',
      () async {
        final preview = _Preview()
          ..pending = Completer()
          ..failStop = failCleanup;
        final runner = HtmlStarterRunner(preview: preview);
        var allowed = true;
        final pending = runner.start(
          directory: '/tmp/site',
          input: input,
          authorizeRead: () {
            if (!allowed) throw StateError('revoked');
          },
        );
        allowed = false;
        preview.pending!.complete(Uri.parse('http://127.0.0.1:1234/token/'));
        await expectLater(
          pending,
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'reason',
              failCleanup ? 'cleanup failed' : 'revoked',
            ),
          ),
        );
        expect(preview.stops, 1);
      },
    );
  }
  test('production runner exports, checks, serves assets, stops, retries and refuses edits', () async {
    final temp = await Directory.systemTemp.createTemp('asg-runner-');
    final parent = await temp.resolveSymbolicLinks();
    addTearDown(() => temp.delete(recursive: true));
    final request = HtmlExportRequest(
      input: input,
      parent: parent,
      folderName: 'runner_site',
    );
    final directory = await HtmlSourceExportNative().export(
      request: request,
      confirmedRequest: request,
      authorizeWrite: () {},
    );
    final runner = ProjectRunnerRegistry().htmlRunner('HTML')!;
    addTearDown(runner.stop);
    final result = await runner.execute(
      RunnerOperation.checkSources,
      directory: directory,
      input: input,
      authorizeRead: () {},
    );
    expect(result.status, RunnerResultStatus.completed);
    expect(result.sourceCheck!.files, 5);
    final url = await runner.start(directory: directory, input: input);
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    for (final path in ['', 'styles.css', 'app.js', 'assets/mark.svg']) {
      final response = await (await client.getUrl(url.resolve(path))).close();
      expect(response.statusCode, 200);
      expect(await utf8.decoder.bind(response).join(), isNotEmpty);
    }
    await runner.stop();
    await expectLater(
      client.getUrl(url).timeout(const Duration(seconds: 2)),
      throwsA(isA<SocketException>()),
    );
    final retry = await runner.start(directory: directory, input: input);
    expect(retry, isNot(url));
    await runner.stop();
    final file = File('$directory/app.js');
    await file.writeAsString('changed');
    await expectLater(
      runner.start(directory: directory, input: input),
      throwsFormatException,
    );
    await expectLater(
      runner.checkSources(
        directory: directory,
        input: input,
        authorizeRead: () {},
      ),
      throwsFormatException,
    );
    expect(await file.readAsString(), 'changed');
  }, skip: !Platform.isMacOS);
}
