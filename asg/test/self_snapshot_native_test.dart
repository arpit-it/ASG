// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('vm')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/self_snapshot_operation.dart';
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
    },
    skip: !Platform.isMacOS,
  );
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
    Future<int> check(bool analyze, Completer<void> stop) async {
      final result = await checkSelfSnapshot(
        snapshot: snapshot,
        sdk: sdk,
        python: '/usr/bin/python3',
        operation: analyze
            ? SelfSnapshotOperation.analyze
            : SelfSnapshotOperation.resolve,
        stop: stop.future,
        stopped: () => stop.isCompleted,
      );
      return result.exitCode;
    }

    expect(await check(false, Completer<void>()), 0);
    expect(await check(true, Completer<void>()), 0);
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
    await expectLater(
      checkSelfSnapshot(
        snapshot: snapshot,
        sdk: sdk,
        python: '/usr/bin/python3',
        operation: SelfSnapshotOperation.build,
        stop: buildStop.future,
        stopped: () => buildStop.isCompleted,
      ),
      throwsStateError,
    );
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
  }, skip: !Platform.isMacOS || sdk.isEmpty);
}
