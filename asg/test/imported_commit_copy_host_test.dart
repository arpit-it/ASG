// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/imported_commit_context.dart';
import 'package:asg/models/imported_commit_copy_request.dart';
import 'package:asg/models/imported_commit_copy_observation.dart';
import 'package:asg/models/imported_commit_proposal.dart';
import 'package:asg/models/imported_commit_proposal_record.dart';
import 'package:asg/models/imported_plan.dart';
import 'package:asg/services/imported_commit_copy_host_native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_commit_proposal_record_test.dart' show capturedCommitPlan;
import 'imported_commit_copy_observation_test.dart' show copyObservationData;

class CopyProcess implements Process {
  final output = StreamController<List<int>>(),
      errors = StreamController<List<int>>();
  final exited = Completer<int>();
  final signals = <ProcessSignal>[];
  void Function(ProcessSignal)? onKill;
  @override
  Stream<List<int>> get stdout => output.stream;
  @override
  Stream<List<int>> get stderr => errors.stream;
  @override
  Future<int> get exitCode => exited.future;
  @override
  int get pid => 98765421;
  @override
  IOSink get stdin => throw StateError('No stdin protocol');
  @override
  bool kill([ProcessSignal signal = ProcessSignal.sigterm]) {
    signals.add(signal);
    if (onKill != null) {
      onKill!(signal);
    } else {
      finish(-9);
    }
    return true;
  }

  void finish([int code = 2]) {
    if (!exited.isCompleted) exited.complete(code);
    if (!output.isClosed) unawaited(output.close());
    if (!errors.isClosed) unawaited(errors.close());
  }
}

class CopyFixture {
  CopyFixture(this.base, this.request);
  final Directory base;
  final ImportedCommitCopyRequest request;
  final children = <CopyProcess>[], temps = <Directory>[];
  final started = Completer<void>();
  final assets = {
    for (final name in [
      'imported_commit_copy.py',
      'imported_commit_source.py',
      'prepare_self_candidate.py',
    ])
      name: '# synthetic trusted fixture',
  };
  int starts = 0, assetReads = 0;
  bool groupAlive = false;
  final kills = <int>[];
  void Function(int)? onGroupKill;
  Future<Map<String, String>> Function()? load;
  Future<Process> Function(CopyProcess)? start;
  void Function(CopyProcess)? respond;
  NativeImportedCommitCopyHost host({
    bool supported = true,
    Duration grace = const Duration(milliseconds: 100),
    Duration deadline = const Duration(seconds: 5),
  }) => NativeImportedCommitCopyHost(
    platformSupported: supported,
    cleanupGrace: grace,
    deadline: deadline,
    groupExists: (_) => groupAlive,
    killGroup: (pid) {
      kills.add(pid);
      if (onGroupKill != null) {
        onGroupKill!(pid);
      } else {
        groupAlive = false;
      }
    },
    loadAssets: () async {
      assetReads++;
      return load == null ? assets : await load!();
    },
    createTemp: () async {
      final d = await Directory('${base.path}/temps').create(recursive: true);
      final temp = await d.createTemp('owned-');
      await Process.run('/bin/chmod', ['0700', temp.path]);
      temps.add(temp);
      return temp;
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
          expect(args.last, '$workingDirectory/request.json');
          expect(await File(args.last).readAsString(), request.requestJson);
          final child = CopyProcess();
          children.add(child);
          await File('$workingDirectory/copy-session')
              .writeAsString('${child.pid}');
          if (!started.isCompleted) started.complete();
          if (start != null) return start!(child);
          (respond ??
              (p) {
                p.output.add(
                  utf8.encode(
                    jsonEncode(
                      copyObservationData(
                        request,
                        prepared: false,
                        knownRun: false,
                      ),
                    ),
                  ),
                );
                p.finish();
              })(child);
          return child;
        },
  );
  Future<void> clean() async {
    for (final c in children) {
      c.finish(-9);
    }
    if (await base.exists()) await base.delete(recursive: true);
  }

  Future<void> readyDirectory() async {
    final run = await Directory(
      '${request.destination}/asg-self-candidate-1234abcd',
    ).create();
    await Process.run('/bin/chmod', ['0700', run.path]);
    await Directory('${run.path}/source-${request.commit}').create();
  }
}

Future<CopyFixture> fixture() async {
  final created = await Directory.systemTemp.createTemp('asg-copy-host-test-');
  final base = Directory(await created.resolveSymbolicLinks());
  final root = await Directory('${base.path}/source').create(),
      output = await Directory('${base.path}/outputs').create();
  final python = File('${base.path}/python');
  await python.writeAsString('# trusted synthetic executable');
  await Process.run('/bin/chmod', ['0700', python.path]);
  final data =
      jsonDecode(capturedCommitPlan().recordJson) as Map<String, dynamic>;
  data['metadata']['root'] = root.path;
  final context = ImportedCommitContext.restore(jsonEncode(data));
  final plan = ImportedPlan(
    text: 'Reviewed original baseline copy',
    context: context.recordJson,
    approved: true,
    recordedAt: DateTime.utc(2026),
  );
  final saved = ImportedCommitProposalRecord.create(
    context: context,
    plan: plan,
    proposal: ImportedCommitProposal.create(
      context: context,
      plan: plan,
      path: 'lib/main.dart',
      replacement: '// changed',
    ),
    recordedAt: DateTime.utc(2026),
  );
  return CopyFixture(
    base,
    ImportedCommitCopyRequest.create(
      saved: saved,
      python: python.path,
      destination: output.path,
      attemptId: 'a' * 32,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late CopyFixture f;
  setUp(() async {
    f = await fixture();
  });
  tearDown(() async => f.clean());
  test('isolated arguments private assets and scoped refusal are cleaned before completion', () async {
    final host = f.host();
    final result = await host.prepare(f.request);
    expect(result.status, ImportedCommitCopyStatus.refused);
    expect(host.lastObservation, same(result));
    expect(host.cleanupConfirmed, true);
    expect(f.starts, 1);
    expect(f.temps.every((d) => !d.existsSync()), true);
    await host.dispose();
  });
  test('prepared receipt requires an actual scoped directory and no pending marker', () async {
    final host = f.host();
    f.respond = (p) {
      p.output.add(utf8.encode(jsonEncode(copyObservationData(f.request))));
      p.finish(0);
    };
    await expectLater(host.prepare(f.request), throwsStateError);
    expect(host.lastObservation!.status, ImportedCommitCopyStatus.prepared);
    await f.readyDirectory();
    final result = await host.prepare(f.request);
    expect(result.status, ImportedCommitCopyStatus.prepared);
    expect(host.cleanupConfirmed, true);
    await File(
      '${f.request.destination}/asg-self-candidate-1234abcd/.asg-imported-copy-pending',
    ).writeAsString('pending');
    await expectLater(host.prepare(f.request), throwsStateError);
    expect(host.lastObservation!.status, ImportedCommitCopyStatus.prepared);
    await host.dispose();
  });
  test(
    'unsupported host and changed destination refuse before asset or dispatch',
    () async {
      final unsupported = f.host(supported: false);
      await expectLater(unsupported.prepare(f.request), throwsStateError);
      expect(f.assetReads, 0);
      await unsupported.dispose();
      await Directory(f.request.destination).delete();
      await Link(f.request.destination).create(f.request.root);
      final host = f.host();
      await expectLater(host.prepare(f.request), throwsStateError);
      expect(f.starts, 0);
      expect(f.assetReads, 0);
      await host.dispose();
    },
  );
  test(
    'Stop during asset loading prevents startup and waits for settlement',
    () async {
      final gate = Completer<Map<String, String>>();
      final loaded = Completer<void>();
      f.load = () {
        loaded.complete();
        return gate.future;
      };
      final host = f.host();
      final pending = host.prepare(f.request);
      final checked = expectLater(pending, throwsStateError);
      await loaded.future;
      var stopped = false;
      final stop = host.cancel().then((_) => stopped = true);
      await Future<void>.delayed(Duration.zero);
      expect(stopped, false);
      gate.complete(f.assets);
      await stop;
      await checked;
      expect(f.starts, 0);
      expect(host.cleanupConfirmed, true);
      await host.dispose();
    },
  );
  test('late startup after Stop is still captured reaped and excluded from overlap', () async {
    final gate = Completer<Process>();
    f.start = (child) => gate.future;
    final host = f.host();
    final pending = host.prepare(f.request);
    final checked = expectLater(pending, throwsStateError);
    await f.started.future;
    final stop = host.cancel();
    await expectLater(host.prepare(f.request), throwsStateError);
    expect(f.starts, 1);
    gate.complete(f.children.single);
    await stop;
    await checked;
    expect(f.children.single.signals, isNotEmpty);
    expect(host.cleanupConfirmed, true);
    await host.dispose();
  });
  test(
    'Stop retains a bounded refusal receipt only as recovery data',
    () async {
      f.respond = (p) {
        p.onKill = (_) {
          p.output.add(
            utf8.encode(
              jsonEncode(copyObservationData(f.request, prepared: false)),
            ),
          );
          p.finish();
        };
      };
      final host = f.host();
      final pending = host.prepare(f.request);
      final checked = expectLater(pending, throwsStateError);
      await f.started.future;
      await host.cancel();
      await checked;
      expect(host.lastObservation!.status, ImportedCommitCopyStatus.refused);
      expect(host.lastObservation!.runName, 'asg-self-candidate-1234abcd');
      expect(host.cleanupConfirmed, true);
      await host.dispose();
    },
  );
  test('Stop during final cleanup revokes a prepared receipt but retains recovery evidence', () async {
    await f.readyDirectory();
    final entered = Completer<void>();
    f.groupAlive = true;
    f.onGroupKill = (_) {
      if (!entered.isCompleted) entered.complete();
    };
    f.respond = (p) {
      p.output.add(utf8.encode(jsonEncode(copyObservationData(f.request))));
      p.finish(0);
    };
    final host = f.host(grace: const Duration(seconds: 2));
    final pending = host.prepare(f.request);
    final checked = expectLater(pending, throwsStateError);
    await entered.future;
    final stopped = host.cancel();
    f.groupAlive = false;
    await stopped;
    await checked;
    expect(host.lastObservation!.status, ImportedCommitCopyStatus.prepared);
    expect(host.cleanupConfirmed, true);
    await host.dispose();
  });
  test(
    'residual owned group is killed and uncertain cleanup remains sticky',
    () async {
      f.groupAlive = true;
      final host = f.host(grace: const Duration(milliseconds: 20));
      await host.prepare(f.request);
      expect(f.kills, [98765421]);
      expect(host.cleanupConfirmed, true);
      f.groupAlive = true;
      f.onGroupKill = (_) {};
      await expectLater(host.prepare(f.request), throwsStateError);
      expect(host.cleanupConfirmed, false);
      final starts = f.starts;
      await expectLater(host.prepare(f.request), throwsStateError);
      expect(f.starts, starts);
      await expectLater(host.dispose(), throwsStateError);
    },
  );
  test('malformed foreign oversized or stderr data never becomes a prepared receipt', () async {
    final host = f.host();
    for (final kind in ['foreign', 'oversized', 'stderr']) {
      f.respond = (p) {
        if (kind == 'stderr') {
          p.errors.add(utf8.encode('private source details'));
          p.finish();
        } else {
          final data = copyObservationData(f.request, prepared: false);
          data['request_sha256'] = 'b' * 64;
          p.output.add(
            utf8.encode(kind == 'oversized' ? 'x' * 32769 : jsonEncode(data)),
          );
          p.finish();
        }
      };
      await expectLater(
        host.prepare(f.request),
        throwsA(
          isA<StateError>().having(
            (e) => '$e',
            'private error',
            isNot(contains('private source details')),
          ),
        ),
      );
      expect(host.lastObservation, isNull);
      expect(host.cleanupConfirmed, true);
    }
    await host.dispose();
  });
}
