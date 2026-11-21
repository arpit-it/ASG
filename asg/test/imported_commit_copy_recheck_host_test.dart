// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_commit_copy_record.dart';
import 'package:asg/models/imported_commit_copy_recheck.dart';
import 'package:asg/services/imported_commit_copy_recheck_host_native.dart';

import 'imported_commit_copy_host_test.dart' as original;
import 'imported_commit_copy_record_test.dart' show copyResult;
import 'imported_commit_copy_recheck_test.dart' show recheckData;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late original.CopyFixture f;
  late ImportedCommitCopyRecheckRequest request;
  final children = <original.CopyProcess>[];
  bool group = false;
  void Function(original.CopyProcess)? respond;
  void Function(int)? kill;
  int starts = 0;
  Completer<void>? started;
  NativeImportedCommitCopyRecheckHost host({
    Duration deadline = const Duration(seconds: 3),
    Duration grace = const Duration(milliseconds: 50),
    Future<Process> Function(original.CopyProcess)? start,
  }) => NativeImportedCommitCopyRecheckHost(
    platformSupported: true,
    deadline: deadline,
    cleanupGrace: grace,
    groupExists: (_) => group,
    killGroup: (pid) {
      if (kill != null) {
        kill!(pid);
      } else {
        group = false;
      }
    },
    loadAssets: () async => {
      'imported_commit_copy_recheck.py': '# trusted fixture',
      'prepare_self_candidate.py': '# trusted fixture',
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
          await File('$workingDirectory/recheck-session')
              .writeAsString('${p.pid}');
          if (started != null && !started!.isCompleted) started!.complete();
          if (start != null) return start(p);
          if (respond != null) {
            respond!(p);
          } else {
            p.output.add(utf8.encode(jsonEncode(recheckData(request))));
            p.finish(0);
          }
          return p;
        },
  );
  setUp(() async {
    f = await original.fixture();
    await f.readyDirectory();
    final history = ImportedCommitCopyRecord.empty(f.request.root)
        .begin(f.request, DateTime.utc(2026))
        .settle(f.request, copyResult(f.request), DateTime.utc(2026));
    request = ImportedCommitCopyRecheckRequest.create(
      history: history,
      python: f.request.python,
      recheckId: 'b' * 32,
    );
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
    'owned read uses isolated trusted assets and cleanup precedes result',
    () async {
      final h = host();
      final value = await h.recheck(request);
      expect(value.status, ImportedCommitCopyRecheckStatus.matching);
      expect(h.cleanupConfirmed, true);
      expect(starts, 1);
      await h.dispose();
    },
  );
  test(
    'pending marker cannot yield an accepted matching observation',
    () async {
      await File(
        '${request.destination}/${request.runName}/.asg-imported-copy-pending',
      ).writeAsString('pending');
      final h = host();
      await expectLater(h.recheck(request), throwsStateError);
      expect(h.cleanupConfirmed, true);
      expect(h.lastObservation, isNotNull);
      await h.dispose();
    },
  );
  test('late startup after Stop is reaped and overlap refused', () async {
    started = Completer();
    final gate = Completer<Process>();
    final h = host(start: (p) => gate.future);
    final pending = h.recheck(request),
        checked = expectLater(h.recheck(request), throwsStateError);
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
    'deadline interrupts owned read and retains no current result',
    () async {
      respond = (_) {};
      final h = host(deadline: const Duration(milliseconds: 80));
      await expectLater(h.recheck(request), throwsStateError);
      expect(children.single.signals, isNotEmpty);
      expect(h.cleanupConfirmed, true);
      await h.dispose();
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
      final pending = h.recheck(request);
      final checked = expectLater(pending, throwsStateError);
      await entered.future;
      final stopping = h.cancel();
      group = false;
      await stopping;
      await checked;
      expect(
        h.lastObservation?.status,
        ImportedCommitCopyRecheckStatus.matching,
      );
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
          final data = recheckData(request);
          data['request_sha256'] = 'e' * 64;
          p.output.add(
            utf8.encode(kind == 'oversized' ? 'x' * 32769 : jsonEncode(data)),
          );
        }
        p.finish(0);
      };
      await expectLater(h.recheck(request), throwsStateError);
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
      await expectLater(h.recheck(request), throwsStateError);
      expect(h.cleanupConfirmed, false);
      final count = starts;
      await expectLater(h.recheck(request), throwsStateError);
      expect(starts, count);
      await expectLater(h.dispose(), throwsStateError);
    },
  );
}
