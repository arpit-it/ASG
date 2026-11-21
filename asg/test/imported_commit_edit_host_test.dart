// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_commit_edit_request.dart';
import 'package:asg/models/imported_commit_edit_observation.dart';
import 'package:asg/services/imported_commit_edit_host_native.dart';

import 'imported_commit_copy_host_test.dart' as original;
import 'imported_commit_edit_observation_test.dart'
    show sampleEditRequest, editData;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late original.CopyFixture f;
  late ImportedCommitEditRequest request;
  final children = <original.CopyProcess>[];
  int starts = 0, assets = 0, temps = 0;
  bool group = false;
  void Function(original.CopyProcess)? respond;
  void Function(int)? kill;
  Completer<void>? started;
  NativeImportedCommitEditHost host({
    Duration deadline = const Duration(seconds: 3),
    Duration grace = const Duration(milliseconds: 50),
    Future<Process> Function(original.CopyProcess)? start,
  }) => NativeImportedCommitEditHost(
    platformSupported: true,
    deadline: deadline,
    cleanupGrace: grace,
    groupExists: (_) => group,
    killGroup: (pid) {
      if (kill == null) {
        group = false;
      } else {
        kill!(pid);
      }
    },
    loadAssets: () async {
      assets++;
      return {
        'imported_commit_edit.py': '# trusted',
        'imported_commit_copy_recheck.py': '# trusted',
        'prepare_self_candidate.py': '# trusted',
      };
    },
    createTemp: () async {
      temps++;
      final d = await f.base.createTemp('owned-edit-');
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
          await File('$workingDirectory/edit-session')
              .writeAsString('${p.pid}');
          if (started != null && !started!.isCompleted) started!.complete();
          if (start != null) return start(p);
          if (respond != null) {
            respond!(p);
          } else {
            p.output.add(utf8.encode(jsonEncode(editData(request))));
            p.finish(0);
          }
          return p;
        },
  );
  setUp(() async {
    f = await original.fixture();
    await f.readyDirectory();
    final output = await Directory('${f.base.path}/proposed').create();
    final data =
        jsonDecode(sampleEditRequest().requestJson) as Map<String, dynamic>;
    data['root'] = f.request.root;
    data['python'] = f.request.python;
    data['source_copy'] =
        '${f.request.destination}/asg-self-candidate-1234abcd/source-${f.request.commit}';
    data['destination'] = output.path;
    request = ImportedCommitEditRequest.restore(jsonEncode(data));
    final run = await Directory('${output.path}/asg-self-candidate-abcdef12')
        .create();
    await Process.run('/bin/chmod', ['0700', run.path]);
    await Directory('${run.path}/source-${request.commit}').create();
    children.clear();
    starts = assets = temps = 0;
    group = false;
    respond = null;
    kill = null;
    started = null;
  });
  tearDown(() async {
    for (final p in children) {
      p.finish(-9);
    }
    await f.clean();
  });
  test('owned writer uses isolated trusted assets and confirms cleanup before publication', () async {
    final h = host();
    expect(
      (await h.prepare(request)).status,
      ImportedCommitEditStatus.prepared,
    );
    expect(h.cleanupConfirmed, true);
    expect(starts, 1);
    await h.dispose();
  });
  test('outside interpreter link resolving into original copy refuses before any assets temp or process effects', () async {
    final program = File('${request.sourceCopy}/repo-program');
    await program.writeAsString('# repository-authored');
    await Process.run('/bin/chmod', ['0700', program.path]);
    await File(request.python).delete();
    await Link(request.python).create(program.path);
    final h = host();
    await expectLater(h.prepare(request), throwsStateError);
    expect(starts, 0);
    expect(assets, 0);
    expect(temps, 0);
    expect(h.cleanupConfirmed, true);
    await h.dispose();
  });
  test('pending proposed output cannot be advertised ready', () async {
    await File(
      '${request.destination}/asg-self-candidate-abcdef12/.asg-imported-edit-pending',
    ).writeAsString('pending');
    final h = host();
    await expectLater(h.prepare(request), throwsStateError);
    expect(h.lastObservation, isNotNull);
    expect(h.cleanupConfirmed, true);
    await h.dispose();
  });
  test('late startup after Stop is reaped and cannot overlap', () async {
    started = Completer();
    final gate = Completer<Process>(), h = host(start: (p) => gate.future);
    final pending = h.prepare(request);
    final checked = expectLater(pending, throwsStateError);
    await started!.future;
    final stop = h.cancel();
    await expectLater(h.prepare(request), throwsStateError);
    gate.complete(children.single);
    await stop;
    await checked;
    expect(children.single.signals, isNotEmpty);
    expect(h.cleanupConfirmed, true);
    await h.dispose();
  });
  test(
    'deadline and malformed private output reject without current receipt',
    () async {
      respond = (_) {};
      final h = host(deadline: const Duration(milliseconds: 80));
      await expectLater(h.prepare(request), throwsStateError);
      expect(h.cleanupConfirmed, true);
      await h.dispose();
      final other = host();
      for (final kind in ['foreign', 'oversized', 'stderr']) {
        respond = (p) {
          if (kind == 'stderr') {
            p.errors.add(utf8.encode('private'));
          } else {
            final data = editData(request);
            data['request_sha256'] = 'e' * 64;
            p.output.add(
              utf8.encode(kind == 'oversized' ? 'x' * 32769 : jsonEncode(data)),
            );
          }
          p.finish(0);
        };
        await expectLater(other.prepare(request), throwsStateError);
      }
      await other.dispose();
    },
  );
  test('Stop during final cleanup revokes prepared receipt but retains recovery evidence', () async {
    group = true;
    final entered = Completer<void>();
    kill = (_) {
      if (!entered.isCompleted) entered.complete();
    };
    final h = host(grace: const Duration(seconds: 2));
    final pending = h.prepare(request);
    final checked = expectLater(pending, throwsStateError);
    await entered.future;
    final stopping = h.cancel();
    group = false;
    await stopping;
    await checked;
    expect(h.lastObservation?.status, ImportedCommitEditStatus.prepared);
    expect(h.cleanupConfirmed, true);
    await h.dispose();
  });
  test(
    'unknown descendant cleanup keeps writer busy and blocks another attempt',
    () async {
      group = true;
      kill = (_) {};
      final h = host();
      await expectLater(h.prepare(request), throwsStateError);
      expect(h.cleanupConfirmed, false);
      final count = starts;
      await expectLater(h.prepare(request), throwsStateError);
      expect(starts, count);
      await expectLater(h.dispose(), throwsStateError);
    },
  );
}
