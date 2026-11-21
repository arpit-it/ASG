// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_head_index_observation.dart';
import 'package:asg/services/imported_head_index_host_native.dart';

import 'imported_commit_copy_host_test.dart' as original;
import 'imported_head_index_observation_test.dart'
    show headIndexRequest, headIndexObservationData;

ImportedHeadIndexRequest forRoot(String root, String python, String id) {
  final d = jsonDecode(headIndexRequest().requestJson) as Map<String, dynamic>;
  return ImportedHeadIndexRequest.restore(
    jsonEncode({...d, 'root': root, 'python': python, 'read_id': id * 32}),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late original.CopyFixture f;
  late ImportedHeadIndexRequest request;
  final children = <original.CopyProcess>[];
  bool group = false;
  void Function(original.CopyProcess)? respond;
  void Function(int)? kill;
  int starts = 0;
  Completer<void>? started;
  NativeImportedHeadIndexHost host({
    Duration deadline = const Duration(seconds: 3),
    Duration grace = const Duration(milliseconds: 50),
    Future<Process> Function(original.CopyProcess)? start,
    Timer Function(Duration, void Function())? createTimer,
  }) => NativeImportedHeadIndexHost(
    platformSupported: true,
    deadline: deadline,
    cleanupGrace: grace,
    createTimer: createTimer,
    groupExists: (_) => group,
    killGroup: (pid) {
      if (kill != null) {
        kill!(pid);
      } else {
        group = false;
      }
    },
    loadAssets: () async => {
      'imported_head_index.py': '# trusted fixture',
      'imported_commit_source.py': '# trusted fixture',
      'imported_index.py': '# trusted fixture',
      'git_head_metadata.py': '# trusted fixture',
    },
    createTemp: () async {
      final d = await f.base.createTemp('recheck-owned-');
      await Process.run('/bin/chmod', ['0700', d.path]);
      return d;
    },
    startProcess:
        (
          exe,
          args, {
          required workingDirectory,
          required runInShell,
          required includeParentEnvironment,
          required environment,
        }) async {
          starts++;
          expect(runInShell, false);
          expect(includeParentEnvironment, false);
          expect(environment, isEmpty);
          expect(args.take(3), ['-I', '-S', '-B']);
          expect(await File(args.last).readAsString(), request.requestJson);
          final p = original.CopyProcess();
          children.add(p);
          await File('$workingDirectory/head-index-session')
              .writeAsString('${p.pid}');
          if (started != null && !started!.isCompleted) started!.complete();
          if (start != null) return start(p);
          if (respond != null) {
            respond!(p);
          } else {
            p.output.add(
              utf8.encode(jsonEncode(headIndexObservationData(request))),
            );
            p.finish(0);
          }
          return p;
        },
  );
  setUp(() async {
    f = await original.fixture();
    await f.readyDirectory();
    request = forRoot(f.request.root, f.request.python, 'a');
    children.clear();
    group = false;
    respond = null;
    kill = null;
    starts = 0;
    started = null;
  });
  tearDown(() async {
    for (final p in children) {
      p.finish(-9);
    }
    await f.clean();
  });
  test(
    'owned index read uses isolated trusted assets and cleanup precedes result',
    () async {
      final h = host();
      final value = await h.inspect(request);
      expect(value.status, ImportedHeadIndexStatus.observed);
      expect(h.cleanupConfirmed, true);
      expect(starts, 1);
      await h.dispose();
    },
  );
  test('changed root blocks another worker and preserves previous dated observation', () async {
    respond = (p) {
      p.output.add(utf8.encode(jsonEncode(headIndexObservationData(request))));
      p.finish(0);
    };
    final h = host();
    await h.inspect(request);
    final retained = h.lastObservation;
    await Directory(request.root).rename('${request.root}-moved');
    await expectLater(h.inspect(request), throwsStateError);
    expect(h.lastObservation, same(retained));
    expect(h.cleanupConfirmed, true);
    await h.dispose();
  });
  test('late startup after Stop is reaped and overlap refused', () async {
    started = Completer();
    final gate = Completer<Process>();
    final h = host(start: (p) => gate.future);
    final pending = h.inspect(request),
        checked = expectLater(h.inspect(request), throwsStateError);
    await started!.future;
    final stopping = h.cancel();
    await checked;
    gate.complete(children.single);
    await expectLater(pending, throwsStateError);
    await stopping;
    expect(children.single.signals, isNotEmpty);
    expect(h.cleanupConfirmed, true);
    await h.dispose();
  });
  test(
    'deadline before startup or during owned read retains no current result',
    () async {
      for (final beforeStartup in [true, false]) {
        started = Completer<void>();
        respond = (_) {};
        late void Function() expire;
        final h = host(
          createTimer: (duration, callback) {
            expect(duration, const Duration(seconds: 3));
            expire = callback;
            if (beforeStartup) callback();
            // Cleanup cancels this owned timer. Wall-clock setup speed cannot
            // decide which lifecycle boundary this test exercises.
            return Timer(const Duration(days: 1), () {});
          },
        );
        final pending = h.inspect(request);
        final checked = expectLater(pending, throwsStateError);
        if (!beforeStartup) {
          await started!.future;
          expire();
        }
        await checked;
        expect(starts, beforeStartup ? 0 : 1);
        if (!beforeStartup) expect(children.single.signals, isNotEmpty);
        expect(h.lastObservation, isNull);
        expect(h.cleanupConfirmed, true);
        await h.dispose();
      }
    },
  );
  test(
    'Stop while final cleanup awaits excludes otherwise matching receipt',
    () async {
      group = true;
      final entered = Completer<void>();
      kill = (_) {
        if (!entered.isCompleted) entered.complete();
      };
      final h = host(grace: const Duration(seconds: 2));
      final pending = h.inspect(request);
      final checked = expectLater(pending, throwsStateError);
      await entered.future;
      final stopping = h.cancel();
      group = false;
      await stopping;
      await checked;
      expect(h.lastObservation, isNull);
      expect(h.cleanupConfirmed, true);
      await h.dispose();
    },
  );
  test('foreign oversized or private stderr data never becomes current observation', () async {
    final h = host();
    for (final kind in ['foreign', 'oversized', 'stderr']) {
      respond = (p) {
        if (kind == 'stderr') {
          p.errors.add(utf8.encode('private'));
        } else {
          final data = headIndexObservationData(request);
          data['request_sha256'] = 'e' * 64;
          p.output.add(
            utf8.encode(
              kind == 'oversized'
                  ? 'x' * (ImportedHeadIndexObservation.responseLimit + 1)
                  : jsonEncode(data),
            ),
          );
        }
        p.finish(0);
      };
      await expectLater(
        h.inspect(request),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
      expect(h.cleanupConfirmed, true);
    }
    await h.dispose();
  });
  test(
    'unknown descendant cleanup remains sticky and prevents overlap',
    () async {
      group = true;
      kill = (_) {};
      final h = host();
      await expectLater(h.inspect(request), throwsStateError);
      expect(h.cleanupConfirmed, false);
      final count = starts;
      await expectLater(h.inspect(request), throwsStateError);
      expect(starts, count);
      await expectLater(h.dispose(), throwsStateError);
    },
  );
  test(
    'interpreter alias into original source refuses before launch',
    () async {
      final target = File('${request.root}/copied-python');
      await target.writeAsString('original authored');
      await Process.run('/bin/chmod', ['0700', target.path]);
      final alias = Link('${f.base.path}/runtime-alias');
      await alias.create(target.path);
      request = forRoot(request.root, alias.path, 'b');
      final h = host();
      await expectLater(h.inspect(request), throwsStateError);
      expect(starts, 0);
      expect(h.cleanupConfirmed, true);
      await h.dispose();
    },
  );
}
