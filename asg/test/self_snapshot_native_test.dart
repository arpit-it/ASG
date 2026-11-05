// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('vm')
library;

import 'dart:async';
import 'dart:io';

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
}
