// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/self_snapshot_operation.dart';
import 'package:asg/models/snapshot_preparation_failure.dart';
import 'package:asg/models/candidate_source_proposal.dart';
import 'package:asg/services/self_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'bundled helper copies exact committed data and preserves source',
    () async {
      final root = await Directory.systemTemp.createTemp('asg-snapshot-test-');
      addTearDown(() => root.delete(recursive: true));
      final source = await Directory('${root.path}/source').create();
      final file = File('${source.path}/example.txt');
      Future<String> git(List<String> arguments) async {
        final result = await Process.run('/usr/bin/git', [
          '-C',
          source.path,
          '-c',
          'core.hooksPath=/dev/null',
          ...arguments,
        ]);
        expect(result.exitCode, 0, reason: result.stderr.toString());
        return (result.stdout as String).trim();
      }

      await git(['init', '-q']);
      await file.writeAsString('committed');
      await git(['add', '.']);
      await git([
        '-c',
        'user.name=Fixture',
        '-c',
        'user.email=fixture@example.invalid',
        '-c',
        'commit.gpgsign=false',
        'commit',
        '-qm',
        'fixture',
      ]);
      final commit = await git(['rev-parse', 'HEAD']);
      await file.writeAsString('dirty');
      final stop = Completer<void>();
      final ready = await prepareSelfSnapshot(
        source: source.path,
        destination: root.path,
        commit: commit,
        python: '/usr/bin/python3',
        stop: stop.future,
        stopped: () => stop.isCompleted,
      );
      expect(ready, endsWith('/source-$commit'));
      expect(await File('$ready/example.txt').readAsString(), 'committed');
      expect(await file.readAsString(), 'dirty');
      final comparison = await compareSelfSnapshot(
        snapshot: ready,
        source: source.path,
        commit: commit,
        python: '/usr/bin/python3',
        stop: stop.future,
        stopped: () => stop.isCompleted,
      );
      expect(comparison.commit, commit);
      expect(comparison.changes, isEmpty);
      await File('$ready/example.txt').writeAsString('modified candidate');
      final changed = await compareSelfSnapshot(
        snapshot: ready,
        source: source.path,
        commit: commit,
        python: '/usr/bin/python3',
        stop: stop.future,
        stopped: () => stop.isCompleted,
      );
      expect(changed.modified, 1);
      expect(changed.changes.single.path, 'example.txt');
      expect(changed.digest, isNot(comparison.digest));
      expect(
        await fingerprintSelfSnapshot(
          snapshot: ready,
          python: '/usr/bin/python3',
          stop: stop.future,
          stopped: () => stop.isCompleted,
        ),
        changed.digest,
      );

      final content = await reviewSelfSnapshotFile(
        snapshot: ready,
        source: source.path,
        commit: commit,
        digest: changed.digest,
        file: 'example.txt',
        python: '/usr/bin/python3',
        stop: stop.future,
        stopped: () => stop.isCompleted,
      );
      expect(content.before.text, 'committed');
      expect(content.after.text, 'modified candidate');
      expect(content.digest, changed.digest);
      await File('$ready/example.txt')
          .writeAsString('changed after comparison');
      await expectLater(
        reviewSelfSnapshotFile(
          snapshot: ready,
          source: source.path,
          commit: commit,
          digest: changed.digest,
          file: 'example.txt',
          python: '/usr/bin/python3',
          stop: stop.future,
          stopped: () => stop.isCompleted,
        ),
        throwsStateError,
      );
      expect(await file.readAsString(), 'dirty');
    },
    skip: !Platform.isMacOS,
  );
  for (final stopAfterPublish in [false, true]) {
    test(
      stopAfterPublish
          ? 'bundled helper identifies the retained run after Stop'
          : 'bundled helper identifies the retained run after publication fails',
      () async {
        final root = await Directory.systemTemp.createTemp(
          'asg-snapshot-recovery-',
        );
        addTearDown(() => root.delete(recursive: true));
        final parent = await root.resolveSymbolicLinks();
        final source = await Directory('$parent/source').create();
        await File('${source.path}/entry').writeAsString('original');

        Future<String> git(List<String> args) async {
          final result = await Process.run('/usr/bin/git', [
            '-C',
            source.path,
            '-c',
            'core.hooksPath=/dev/null',
            ...args,
          ]);
          expect(result.exitCode, 0, reason: result.stderr.toString());
          return (result.stdout as String).trim();
        }

        await git(['init', '-q']);
        await git(['add', 'entry']);
        await git([
          '-c',
          'user.name=Fixture',
          '-c',
          'user.email=fixture@example.invalid',
          '-c',
          'commit.gpgsign=false',
          'commit',
          '-qm',
          'fixture',
        ]);
        final commit = await git(['rev-parse', 'HEAD']);
        final barrier = File('$parent/after-publication');
        final launcher = await File('$parent/fixture-python')
            .writeAsString('''#!/usr/bin/python3
import os
import runpy
import signal
import sys
import time
from pathlib import Path
main = runpy.run_path(sys.argv[3])['main']
helpers = main.__globals__
original_rename = helpers['exclusive_rename']
signal.signal(signal.SIGTERM, helpers['request_stop'])
def after_publication(run_fd, staging, target):
    original_rename(run_fd, staging, target)
    parent = Path(sys.argv[-1])
    if ${stopAfterPublish ? 'True' : 'False'}:
        (parent / 'after-publication').write_text(str(os.getpid()))
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            helpers['check_stop']()
            time.sleep(0.01)
        raise RuntimeError('Fixture did not receive Stop')
    run, = parent.glob('asg-self-candidate-*')
    (run / target / 'entry').write_text('changed after publication')
helpers['exclusive_rename'] = after_publication
raise SystemExit(main(sys.argv[4:]))
''');
        expect(
          (await Process.run('/bin/chmod', ['700', launcher.path])).exitCode,
          0,
        );
        Future<String> prepare(String python, Completer<void> stop) =>
            prepareSelfSnapshot(
              source: source.path,
              destination: parent,
              commit: commit,
              python: python,
              stop: stop.future,
              stopped: () => stop.isCompleted,
            );
        Directory retainedRun() => Directory(parent)
            .listSync()
            .whereType<Directory>()
            .singleWhere(
              (directory) =>
                  directory.path.startsWith('$parent/asg-self-candidate-'),
            );
        final stop = Completer<void>();
        final failure = expectLater(
          prepare(launcher.path, stop),
          throwsA(
            isA<SnapshotPreparationFailure>().having(
              (failure) => failure.runPath,
              'run folder',
              predicate<String>(
                (reported) => reported == retainedRun().path,
                'the retained run folder',
              ),
            ),
          ),
        );
        if (stopAfterPublish) {
          final watch = Stopwatch()..start();
          try {
            while (!await barrier.exists() &&
                watch.elapsed < const Duration(seconds: 5)) {
              await Future<void>.delayed(const Duration(milliseconds: 20));
            }
            expect(await barrier.exists(), isTrue);
          } finally {
            stop.complete();
            await failure;
          }
          final pid = await barrier.readAsString();
          final process = await Process.run('/bin/ps', [
            '-p',
            pid,
            '-o',
            'pid=',
          ]);
          expect(process.stdout.toString().trim(), isEmpty);
        } else {
          await failure;
        }
        final failed = retainedRun();
        expect(
          await File('${failed.path}/source-$commit/entry').readAsString(),
          stopAfterPublish ? 'original' : 'changed after publication',
        );
        expect(await inspectIncompleteSnapshots(parent), isEmpty);
        final ready = await prepare('/usr/bin/python3', Completer<void>());
        expect(ready, isNot(startsWith(failed.path)));
        expect(await File('$ready/entry').readAsString(), 'original');
        expect(await File('${source.path}/entry').readAsString(), 'original');
      },
      skip: !Platform.isMacOS,
    );
  }

  test('native preparation rejects invalid recovery receipts', () async {
    final root = await Directory.systemTemp.createTemp('asg-recovery-receipt-');
    addTearDown(() => root.delete(recursive: true));
    final parent = await root.resolveSymbolicLinks();
    final run = await Directory('$parent/asg-self-candidate-a1b2c3d4').create();
    await Link('$parent/asg-self-candidate-a1b2c3d5').create(run.path);
    const receipt = 'ASG_SNAPSHOT_RECOVERY_V1 asg-self-candidate-a1b2c3d4\n';
    final launcher = File('$parent/fixture-python');
    final samples = [
      (1, '', '${receipt}extra\n'),
      (1, '', 'ASG_SNAPSHOT_RECOVERY_V1 ../asg-self-candidate-a1b2c3d4\n'),
      (1, '', 'ASG_SNAPSHOT_RECOVERY_V1 asg-self-candidate-a1b2c3d5\n'),
      (1, '', 'ASG_SNAPSHOT_RECOVERY_V1 asg-self-candidate-a1b2c3d6\n'),
      (1, '/unverified\n', receipt),
      (2, '', receipt),
    ];
    for (final (exitCode, output, error) in samples) {
      await launcher.writeAsString(
        '#!/usr/bin/python3\nimport sys\n'
        'sys.stdout.write(${jsonEncode(output)})\n'
        'sys.stderr.write(${jsonEncode(error)})\n'
        'raise SystemExit($exitCode)\n',
      );
      expect(
        (await Process.run('/bin/chmod', ['700', launcher.path])).exitCode,
        0,
      );
      await expectLater(
        prepareSelfSnapshot(
          source: parent,
          destination: parent,
          commit: 'a' * 40,
          python: launcher.path,
          stop: Completer<void>().future,
          stopped: () => false,
        ),
        throwsStateError,
        reason: '$exitCode, $output, $error',
      );
    }
  }, skip: !Platform.isMacOS);

  test('Stop reaps Git blocked on a loose object', () async {
    final root = await Directory.systemTemp.createTemp('asg-snapshot-stop-');
    addTearDown(() => root.delete(recursive: true));
    final source = await Directory('${root.path}/source').create();
    final init = await Process.run('/usr/bin/git', [
      '-C',
      source.path,
      'init',
      '-q',
    ]);
    expect(init.exitCode, 0);
    final commit = 'a' * 40;
    final loose = await Directory('${source.path}/.git/objects/aa').create();
    final fifo = await Process.run('/usr/bin/mkfifo', [
      '${loose.path}/${commit.substring(2)}',
    ]);
    expect(fifo.exitCode, 0);
    final resolved = await source.resolveSymbolicLinks();
    Future<List<int>> children() async {
      final result = await Process.run('/bin/ps', ['-axo', 'pid=,command=']);
      expect(result.exitCode, 0);
      return (result.stdout as String)
          .split('\n')
          .where(
            (line) => line.contains(
              '/usr/bin/git --no-replace-objects -C $resolved cat-file -t $commit',
            ),
          )
          .map((line) => int.parse(line.trimLeft().split(RegExp(r'\s+')).first))
          .toList();
    }

    final stop = Completer<void>();
    final operation = prepareSelfSnapshot(
      source: source.path,
      destination: root.path,
      commit: commit,
      python: '/usr/bin/python3',
      stop: stop.future,
      stopped: () => stop.isCompleted,
    );
    final failure = expectLater(operation, throwsStateError);
    final watch = Stopwatch()..start();
    List<int> owned = [];
    try {
      while (watch.elapsed < const Duration(seconds: 5)) {
        owned = await children();
        if (owned.isNotEmpty) break;
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      expect(owned, hasLength(1));
    } finally {
      stop.complete();
      await failure;
      final remaining = await children();
      for (final pid in remaining.where(owned.contains)) {
        Process.killPid(pid, ProcessSignal.sigkill);
      }
      expect(remaining, isEmpty);
    }
  }, skip: !Platform.isMacOS);
  test('inspection finds only direct incomplete staging directories', () async {
    final root = await Directory.systemTemp.createTemp('asg-snapshot-inspect-');
    addTearDown(() => root.delete(recursive: true));
    final incomplete = await Directory(
      '${root.path}/asg-self-candidate-a1b2c3d4/incomplete',
    ).create(recursive: true);
    final ready = await Directory(
      '${root.path}/asg-self-candidate-b1c2d3e4/source-${'a' * 40}',
    ).create(recursive: true);
    final other = await Directory('${root.path}/unrelated/incomplete')
        .create(recursive: true);
    await Link('${root.path}/asg-self-candidate-c1d2e3f4')
        .create(incomplete.parent.path);
    final linked = await Directory('${root.path}/asg-self-candidate-d1e2f3g4')
        .create();
    await Link('${linked.path}/incomplete').create(other.path);
    final rootPath = await root.resolveSymbolicLinks();
    expect(await inspectIncompleteSnapshots(root.path), [
      '$rootPath/asg-self-candidate-a1b2c3d4/incomplete',
    ]);
    expect(await ready.exists(), isTrue);
    expect(await other.exists(), isTrue);
  }, skip: !Platform.isMacOS);
  test('actual approved replacement forks a new unverified snapshot', () async {
    final root = await Directory.systemTemp.createTemp('asg-proposal-native-');
    addTearDown(() => root.delete(recursive: true));
    final parent = await root.resolveSymbolicLinks();
    final source = await Directory('$parent/source/asg/lib')
        .create(recursive: true);
    final checkout = Directory('$parent/source');
    const before =
        '// SPDX-License-Identifier: MPL-2.0\n// Copyright 2026 Arpit Sinha\n\nvoid main() {}\n';
    const after =
        '// SPDX-License-Identifier: MPL-2.0\n// Copyright 2026 Arpit Sinha\n\nvoid main() { print("new candidate"); }\n';
    final file = File('${source.path}/main.dart');
    await file.writeAsString(before);
    Future<String> git(List<String> arguments) async {
      final result = await Process.run('/usr/bin/git', [
        '-C',
        checkout.path,
        '-c',
        'core.hooksPath=/dev/null',
        ...arguments,
      ]);
      expect(result.exitCode, 0, reason: result.stderr.toString());
      return (result.stdout as String).trim();
    }

    await git(['init', '-q']);
    await git(['add', '.']);
    await git([
      '-c',
      'user.name=Fixture',
      '-c',
      'user.email=fixture@example.invalid',
      '-c',
      'commit.gpgsign=false',
      'commit',
      '-qm',
      'fixed source',
    ]);
    final commit = await git(['rev-parse', 'HEAD']);
    await file.writeAsString('dirty source retained');
    final stop = Completer<void>();
    final snapshot = await prepareSelfSnapshot(
      source: checkout.path,
      destination: parent,
      commit: commit,
      python: '/usr/bin/python3',
      stop: stop.future,
      stopped: () => stop.isCompleted,
    );
    await Directory('$snapshot/empty').create();
    final captured = await readCandidateProposalSource(
      snapshot: snapshot,
      file: 'asg/lib/main.dart',
      python: '/usr/bin/python3',
      stop: stop.future,
      stopped: () => stop.isCompleted,
    );
    expect(captured.before, before);
    final destination = await Directory('$parent/output').create();
    final proposal = CandidateSourceProposal.create(
      snapshot: snapshot,
      python: '/usr/bin/python3',
      trustedSource: checkout.path,
      source: captured,
      replacement: after,
      destination: destination.path,
      runName: 'asg-self-candidate-1234abcd',
    );
    final result = await applyCandidateProposal(
      proposal: proposal,
      stop: stop.future,
      stopped: () => stop.isCompleted,
    );
    expect(
      await File('${result.path}/asg/lib/main.dart').readAsString(),
      after,
    );
    expect(await File('$snapshot/asg/lib/main.dart').readAsString(), before);
    expect(await file.readAsString(), 'dirty source retained');
    expect(await Directory('${result.path}/empty').exists(), isTrue);
    expect(result.sourceDigest, captured.digest);
    expect(result.digest, isNot(captured.digest));
    final changed = await compareSelfSnapshot(
      snapshot: result.path,
      source: checkout.path,
      commit: commit,
      python: '/usr/bin/python3',
      stop: stop.future,
      stopped: () => stop.isCompleted,
    );
    expect(changed.modified, 1);
    await File('$snapshot/asg/lib/main.dart')
        .writeAsString('$before// stale\n');
    await expectLater(
      applyCandidateProposal(
        proposal: proposal,
        stop: stop.future,
        stopped: () => stop.isCompleted,
      ),
      throwsStateError,
    );
    expect(
      await File('${result.path}/asg/lib/main.dart').readAsString(),
      after,
    );
  }, skip: !Platform.isMacOS);

  test('offline checks refuse a snapshot-owned Python before launch', () async {
    final root = await Directory.systemTemp.createTemp(
      'asg-offline-check-python-',
    );
    addTearDown(() => root.delete(recursive: true));
    final parent = await root.resolveSymbolicLinks();
    final snapshot = '$parent/asg-self-candidate-a1b2c3d4/source-${'a' * 40}';
    final project = await Directory('$snapshot/asg').create(recursive: true);
    await File('${project.path}/pubspec.yaml').writeAsString('name: fixture\n');
    final marker = File('$parent/interpreter-launched');
    final interpreter = await File(
      '$snapshot/fixture-python',
    ).writeAsString('#!/bin/sh\nprintf launched > "${marker.path}"\nexit 42\n');
    final chmod = await Process.run('/bin/chmod', ['700', interpreter.path]);
    expect(chmod.exitCode, 0, reason: chmod.stderr.toString());
    final alias = await Link('$parent/linked-python').create(interpreter.path);
    final caseAlias = interpreter.path.replaceFirst(
      'source-${'a' * 40}',
      'SOURCE-${'A' * 40}',
    );
    final stop = Completer<void>();
    for (final python in [
      interpreter.path,
      alias.path,
      if (await File(caseAlias).exists()) caseAlias,
    ]) {
      try {
        await expectLater(
          checkSelfSnapshot(
            snapshot: snapshot,
            sdk: '$parent/unused-sdk',
            python: python,
            operation: SelfSnapshotOperation.resolve,
            stop: stop.future,
            stopped: () => stop.isCompleted,
          ),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'Choose a trusted Python outside the candidate.',
            ),
          ),
          reason: python,
        );
      } finally {
        expect(await marker.exists(), isFalse, reason: python);
      }
    }
  }, skip: !Platform.isMacOS);

  const sdk = String.fromEnvironment('ASG_SNAPSHOT_TEST_SDK');
  test('confined offline checks and Stop during SDK lock wait', () async {
    final root = await Directory.systemTemp.createTemp('asg-offline-check-');
    addTearDown(() => root.delete(recursive: true));
    final parent = await root.resolveSymbolicLinks();
    final snapshot = '$parent/asg-self-candidate-a1b2c3d4/source-${'a' * 40}';
    final project = await Directory('$snapshot/asg').create(recursive: true);
    await Directory('${project.path}/lib').create();
    final manifest = File('${project.path}/pubspec.yaml');
    const original = 'name: asg\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\n';
    await manifest.writeAsString(original);
    await File('${project.path}/lib/main.dart').writeAsString('void main() {}');
    Future<int> check(
      bool analyze,
      Completer<void> stop, {
      String python = '/usr/bin/python3',
    }) async {
      final result = await checkSelfSnapshot(
        snapshot: snapshot,
        sdk: sdk,
        python: python,
        operation: analyze
            ? SelfSnapshotOperation.analyze
            : SelfSnapshotOperation.resolve,
        stop: stop.future,
        stopped: () => stop.isCompleted,
      );
      return result.exitCode;
    }

    expect(await check(false, Completer<void>()), 0);
    final trustedAlias = await Link('$parent/trusted-python')
        .create('/usr/bin/python3');
    expect(await check(true, Completer<void>(), python: trustedAlias.path), 0);
    expect(await manifest.readAsString(), original);

    final sentinel = File('$parent/external-sentinel');
    await sentinel.writeAsString('outside stays unchanged');
    final packageConfig = File(
      '${project.path}/.dart_tool/package_config.json',
    );
    await packageConfig.delete();
    final link = await Process.run('/bin/ln', [
      sentinel.path,
      packageConfig.path,
    ]);
    expect(link.exitCode, 0, reason: link.stderr.toString());
    await expectLater(check(false, Completer<void>()), throwsStateError);
    expect(await sentinel.readAsString(), 'outside stays unchanged');
    await packageConfig.delete();

    final output = await Directory('${project.path}/build/web')
        .create(recursive: true);
    final existing = File('${output.path}/index.html');
    await existing.writeAsString('previous output');
    final buildStop = Completer<void>();
    final failedBuild = await checkSelfSnapshot(
      snapshot: snapshot,
      sdk: sdk,
      python: '/usr/bin/python3',
      operation: SelfSnapshotOperation.build,
      stop: buildStop.future,
      stopped: () => buildStop.isCompleted,
    );
    expect(failedBuild.exitCode, isNot(0));
    expect(failedBuild.artifactPath, isNull);
    expect(await existing.readAsString(), 'previous output');

    final locker = await Process.start('/usr/bin/python3', [
      '-u',
      '-c',
      'import fcntl, sys; f=open(sys.argv[1], "r+b"); '
          'fcntl.lockf(f, fcntl.LOCK_EX); print("locked"); sys.stdin.read()',
      '$sdk/bin/cache/lockfile',
    ]);
    try {
      expect(
        await locker.stdout
            .transform(utf8.decoder)
            .transform(const LineSplitter())
            .first
            .timeout(const Duration(seconds: 5)),
        'locked',
      );
      final overlay = Directory('${project.path}/.dart_tool/asg_pub_cache');
      await overlay.delete(recursive: true);
      final stop = Completer<void>();
      final operation = check(false, stop);
      final stopped = expectLater(operation, throwsStateError);
      final watch = Stopwatch()..start();
      try {
        while (!await overlay.exists() &&
            watch.elapsed < const Duration(seconds: 5)) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        expect(await overlay.exists(), isTrue);
        await expectLater(
          check(true, Completer<void>()).timeout(const Duration(seconds: 5)),
          throwsStateError,
        );
      } finally {
        stop.complete();
        await stopped.timeout(const Duration(seconds: 12));
      }
      final ps = await Process.run('/bin/ps', ['-axo', 'command=']);
      expect(
        (ps.stdout as String)
            .split('\n')
            .any(
              (line) =>
                  line.contains(
                    '--offline-snapshot-check --operation resolve',
                  ) &&
                  line.endsWith('--directory ${project.path}'),
            ),
        isFalse,
      );
      expect(await manifest.readAsString(), original);
    } finally {
      await locker.stdin.close();
      await locker.exitCode.timeout(const Duration(seconds: 5));
    }
    expect(await check(false, Completer<void>()), 0);
  }, skip: !Platform.isMacOS || sdk.isEmpty);
}
