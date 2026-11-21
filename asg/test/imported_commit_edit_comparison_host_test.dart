// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_commit_edit_comparison.dart';
import 'package:asg/services/imported_commit_edit_comparison_host_native.dart';

import 'imported_commit_copy_host_test.dart' as original;
import 'imported_commit_edit_comparison_controller_test.dart'
    show comparisonData, sampleComparisonRequest;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late original.CopyFixture f;
  late ImportedCommitEditComparisonRequest request;
  final children = <original.CopyProcess>[];
  bool group = false;
  void Function(original.CopyProcess)? respond;
  void Function(int)? kill;
  int starts = 0;
  Completer<void>? started;
  NativeImportedCommitEditComparisonHost host({
    Duration deadline = const Duration(seconds: 3),
    Duration grace = const Duration(milliseconds: 50),
    Future<Process> Function(original.CopyProcess)? start,
  }) => NativeImportedCommitEditComparisonHost(
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
      'imported_commit_edit_comparison.py': '# trusted fixture',
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
          await File('$workingDirectory/comparison-session')
              .writeAsString('${p.pid}');
          if (started != null && !started!.isCompleted) started!.complete();
          if (start != null) return start(p);
          if (respond != null) {
            respond!(p);
          } else {
            p.output.add(utf8.encode(jsonEncode(comparisonData(request))));
            p.finish(0);
          }
          return p;
        },
  );
  setUp(() async {
    f = await original.fixture();
    await f.readyDirectory();
    final data = jsonDecode(
      sampleComparisonRequest().requestJson,
    ) as Map<String, dynamic>;
    final destination = '${f.base.path}/proposed';
    final proposed =
        '$destination/asg-self-candidate-abcdef13/source-${f.request.commit}';
    await Directory(proposed).create(recursive: true);
    await Process.run('/bin/chmod', ['0700', Directory(proposed).parent.path]);
    request = ImportedCommitEditComparisonRequest.restore(
      jsonEncode({
        ...data,
        'root': f.request.root,
        'python': f.request.python,
        'commit': f.request.commit,
        'tree': f.request.tree,
        'original_destination': f.request.destination,
        'original_run': 'asg-self-candidate-1234abcd',
        'original_copy':
            '${f.request.destination}/asg-self-candidate-1234abcd/source-${f.request.commit}',
        'proposed_destination': destination,
        'proposed_run': 'asg-self-candidate-abcdef13',
        'proposed_copy': proposed,
      }),
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
      final value = await h.compare(request);
      expect(value.status, ImportedCommitEditComparisonStatus.matching);
      expect(h.cleanupConfirmed, true);
      expect(starts, 1);
      await h.dispose();
    },
  );
  test('pending marker cannot yield an accepted matching observation', () async {
    await File(
      '${request.proposedDestination}/${request.proposedRun}/.asg-imported-copy-pending',
    ).writeAsString('pending');
    final h = host();
    await expectLater(h.compare(request), throwsStateError);
    expect(h.cleanupConfirmed, true);
    expect(h.lastObservation, isNotNull);
    await h.dispose();
  });
  test('late startup after Stop is reaped and overlap refused', () async {
    started = Completer();
    final gate = Completer<Process>();
    final h = host(start: (p) => gate.future);
    final pending = h.compare(request),
        checked = expectLater(h.compare(request), throwsStateError);
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
      await expectLater(h.compare(request), throwsStateError);
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
      final pending = h.compare(request);
      final checked = expectLater(pending, throwsStateError);
      await entered.future;
      final stopping = h.cancel();
      group = false;
      await stopping;
      await checked;
      expect(
        h.lastObservation?.status,
        ImportedCommitEditComparisonStatus.matching,
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
          final data = comparisonData(request);
          data['request_sha256'] = 'e' * 64;
          p.output.add(
            utf8.encode(kind == 'oversized' ? 'x' * 32769 : jsonEncode(data)),
          );
        }
        p.finish(0);
      };
      await expectLater(h.compare(request), throwsStateError);
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
      await expectLater(h.compare(request), throwsStateError);
      expect(h.cleanupConfirmed, false);
      final count = starts;
      await expectLater(h.compare(request), throwsStateError);
      expect(starts, count);
      await expectLater(h.dispose(), throwsStateError);
    },
  );
  test('outside interpreter symlink into either saved output refuses before process entry', () async {
    final original = request;
    for (final copy in [request.originalCopy, request.proposedCopy]) {
      final target = File('$copy/copied-python');
      await target.writeAsString('repository authored');
      await Process.run('/bin/chmod', ['0700', target.path]);
      final alias = Link('${f.base.path}/runtime-alias');
      await alias.create(target.path);
      request = ImportedCommitEditComparisonRequest.restore(
        jsonEncode({
          ...jsonDecode(original.requestJson) as Map<String, dynamic>,
          'python': alias.path,
        }),
      );
      final h = host();
      await expectLater(h.compare(request), throwsStateError);
      expect(starts, 0);
      expect(h.cleanupConfirmed, true);
      await h.dispose();
      await alias.delete();
    }
  });
}
