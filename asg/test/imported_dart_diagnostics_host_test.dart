// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_commit_edit_comparison.dart';
import 'package:asg/services/imported_dart_diagnostics_host_native.dart';
import 'package:asg/services/imported_dart_diagnostics_host_stub.dart';
import 'package:asg/models/imported_dart_diagnostics.dart';

import 'imported_commit_copy_host_test.dart' as original;
import 'imported_commit_edit_comparison_controller_test.dart'
    show sampleComparisonRequest, preparedEdits;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late original.CopyFixture f;
  late ImportedCommitEditComparisonRequest request;
  late String sdkRoot;
  late ImportedDartDiagnosticsRequest diagnosticRequest;
  ImportedDartSdkIdentity sdk() => ImportedDartSdkIdentity.create(
    root: sdkRoot,
    version: '3.13.5',
    runtimeHash: 'a' * 64,
    analyzerHash: 'b' * 64,
    libraryHash: 'c' * 64,
    libraryFiles: 1,
    libraryBytes: 100,
  );
  Map<String, dynamic> diagnosticData() => {
    'version': 1,
    'scope': 'imported-dart-diagnostics',
    'request_sha256': diagnosticRequest.digest,
    'run_id': diagnosticRequest.runId,
    'comparison_request_sha256': request.digest,
    'sdk_identity_sha256': sdk().digest,
    'selected_path': request.selectedPath,
    'source_sha256': (jsonDecode(request.requestJson) as Map)['after_sha256'],
    'status': 'clean',
    'reason': null,
    'protocol_version': '1.40.1',
    'diagnostics': [],
    'source_verified': false,
    'project_verified': false,
    'mutation_authorized': false,
    'execution_authorized': false,
    'recorded_at': '2026-11-21T00:00:00.000Z',
  };
  final children = <original.CopyProcess>[];
  bool group = false;
  void Function(original.CopyProcess)? respond;
  void Function(int)? kill;
  int starts = 0;
  Completer<void>? started;
  NativeImportedDartDiagnosticsHost host({
    Duration deadline = const Duration(seconds: 3),
    Duration grace = const Duration(milliseconds: 50),
    Future<Process> Function(original.CopyProcess)? start,
    Timer Function(Duration, void Function())? createTimer,
  }) => NativeImportedDartDiagnosticsHost(
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
      'imported_dart_diagnostics.py': '# trusted fixture',
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
          final payload = jsonDecode(
            await File(args.last).readAsString(),
          ) as Map<String, dynamic>;
          expect(payload['comparison_request'], request.requestJson);
          expect(
            payload['scope'],
            anyOf(
              'imported-dart-sdk-review-request',
              'imported-dart-diagnostics-request',
            ),
          );
          final p = original.CopyProcess();
          children.add(p);
          await File('$workingDirectory/diagnostics-session')
              .writeAsString('${p.pid}');
          if (started != null && !started!.isCompleted) started!.complete();
          if (start != null) return start(p);
          if (respond != null) {
            respond!(p);
          } else {
            p.output.add(
              utf8.encode(
                payload['scope'] == 'imported-dart-sdk-review-request'
                    ? sdk().recordJson
                    : jsonEncode(diagnosticData()),
              ),
            );
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
    sdkRoot = '${f.base.path}/sdk';
    await Directory(sdkRoot).create();
    diagnosticRequest = ImportedDartDiagnosticsRequest.restore(
      jsonEncode({
        'version': 1,
        'scope': 'imported-dart-diagnostics-request',
        'comparison_request': request.requestJson,
        'comparison_receipt_sha256': 'c' * 64,
        'sdk_identity': sdk().recordJson,
        'replacement': preparedEdits().lastPrepared!.request.replacement,
        'run_id': 'd' * 32,
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
      final value = await h.reviewSdk(comparison: request, sdkRoot: sdkRoot);
      expect(value.digest, sdk().digest);
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
    await expectLater(
      h.reviewSdk(comparison: request, sdkRoot: sdkRoot),
      throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
    );
    expect(h.cleanupConfirmed, true);
    expect(h.lastObservation, isNull);
    await h.dispose();
  });
  test('late startup after Stop is reaped and overlap refused', () async {
    started = Completer();
    final gate = Completer<Process>();
    final h = host(start: (p) => gate.future);
    final pending = h.reviewSdk(comparison: request, sdkRoot: sdkRoot),
        checked = expectLater(
          h.reviewSdk(comparison: request, sdkRoot: sdkRoot),
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
        );
    await started!.future;
    final stopping = h.cancel();
    await checked;
    gate.complete(children.single);
    await expectLater(
      pending,
      throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
    );
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
        final pending = h.reviewSdk(comparison: request, sdkRoot: sdkRoot);
        final checked = expectLater(
          pending,
          throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
        );
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
      final pending = h.reviewSdk(comparison: request, sdkRoot: sdkRoot);
      final checked = expectLater(
        pending,
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
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
          final data = jsonDecode(sdk().recordJson) as Map<String, dynamic>;
          data['request_sha256'] = 'e' * 64;
          p.output.add(
            utf8.encode(kind == 'oversized' ? 'x' * 32769 : jsonEncode(data)),
          );
        }
        p.finish(0);
      };
      await expectLater(
        h.reviewSdk(comparison: request, sdkRoot: sdkRoot),
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
      await expectLater(
        h.reviewSdk(comparison: request, sdkRoot: sdkRoot),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
      expect(h.cleanupConfirmed, false);
      final count = starts;
      await expectLater(
        h.reviewSdk(comparison: request, sdkRoot: sdkRoot),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
      expect(starts, count);
      await expectLater(
        h.dispose(),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
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
      await expectLater(
        h.reviewSdk(comparison: request, sdkRoot: sdkRoot),
        throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
      );
      expect(starts, 0);
      expect(h.cleanupConfirmed, true);
      await h.dispose();
      await alias.delete();
    }
  });
  test('diagnostics receipt is parsed only after cleanup and retained across refused review', () async {
    final h = host();
    final value = await h.diagnose(diagnosticRequest);
    expect(value.status, ImportedDartDiagnosticsStatus.clean);
    expect(h.lastObservation, same(value));
    expect(h.cleanupConfirmed, true);
    respond = (p) {
      p.output.add(
        utf8.encode(
          jsonEncode({...diagnosticData(), 'request_sha256': 'e' * 64}),
        ),
      );
      p.finish(0);
    };
    await expectLater(h.diagnose(diagnosticRequest), throwsFormatException);
    expect(h.lastObservation, same(value));
    await h.dispose();
  });
  test('SDK alias or overlap refuses before helper launch', () async {
    final h = host();
    final alias = Link('${f.base.path}/sdk-alias');
    await alias.create(sdkRoot);
    for (final invalid in [
      alias.path,
      request.root,
      request.originalCopy,
      request.proposedDestination,
    ]) {
      await expectLater(
        h.reviewSdk(comparison: request, sdkRoot: invalid),
        throwsA(isA<StateError>()),
      );
    }
    expect(starts, 0);
    expect(h.cleanupConfirmed, true);
    await h.dispose();
  });
  test('unsupported platform has no worker or current observation', () async {
    final h = UnsupportedImportedDartDiagnosticsHost();
    expect(h.supported, false);
    expect(h.cleanupConfirmed, true);
    await expectLater(
      h.reviewSdk(comparison: request, sdkRoot: sdkRoot),
      throwsStateError,
    );
    await expectLater(h.diagnose(diagnosticRequest), throwsStateError);
    expect(h.lastObservation, isNull);
    await h.cancel();
    await h.dispose();
  });
}
