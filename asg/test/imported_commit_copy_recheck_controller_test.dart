// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/imported_commit_copy_recheck_controller.dart';
import 'package:asg/models/imported_commit_copy_recheck.dart';
import 'package:asg/services/imported_commit_copy_recheck_host.dart';
import 'package:asg/services/imported_commit_copy_recheck_store.dart';
import 'package:asg/services/imported_commit_copy_store.dart';

import 'imported_commit_copy_recheck_test.dart'
    show preparedCopyHistory, recheckResult;
import 'imported_commit_copy_controller_test.dart'
    show CopyRecords, copyRecords, waitUntil;

Future<CopyRecords> recheckRecords() async {
  final r = await copyRecords();
  r.values[ImportedCommitCopyStore.key('/project')] =
      preparedCopyHistory().recordJson;
  r.updatesSeen.clear();
  return r;
}

class RecheckHost implements ImportedCommitCopyRecheckHost {
  int calls = 0, cancels = 0;
  String status = 'matching';
  bool clean = true, fail = false, failCleanup = false, supportedValue = true;
  Completer<ImportedCommitCopyRecheckObservation>? gate;
  void Function(ImportedCommitCopyRecheckRequest)? onRead;
  @override
  bool get supported => supportedValue;
  @override
  bool get cleanupConfirmed => clean;
  @override
  ImportedCommitCopyRecheckObservation? get lastObservation => null;
  @override
  Future<ImportedCommitCopyRecheckObservation> recheck(
    ImportedCommitCopyRecheckRequest request,
  ) async {
    calls++;
    onRead?.call(request);
    if (fail) throw StateError('private');
    return gate == null
        ? recheckResult(request, status: status)
        : await gate!.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (failCleanup) throw StateError('private cleanup');
    clean = true;
    if (gate != null && !gate!.isCompleted) {
      gate!.completeError(StateError('stopped'));
    }
  }

  @override
  Future<void> dispose() => cancel();
}

ImportedCommitCopyRecheckController recheckController(
  CopyRecords r,
  RecheckHost host, {
  String? expectedDigest,
}) {
  var id = 0;
  return ImportedCommitCopyRecheckController(
    root: '/project',
    store: ImportedCommitCopyRecheckStore(r),
    host: host,
    expectedHistoryDigest: expectedDigest,
    recheckId: () => (++id).toRadixString(16).padLeft(32, '0'),
  );
}

void main() {
  test(
    'load and explicit native read use only zero-update durable fences',
    () async {
      final r = await recheckRecords(),
          h = RecheckHost(),
          before = Map<String, String>.of(r.values);
      final c = recheckController(r, h);
      await c.load();
      expect(h.calls, 0);
      expect(c.canRecheck, true);
      await c.recheck(c.request!);
      expect(h.calls, 1);
      expect(c.result!.status, ImportedCommitCopyRecheckStatus.matching);
      expect(c.resultCurrent, true);
      expect(r.values, before);
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      c.dispose();
    },
  );
  test('clicked history and runtime changes prevent dispatch', () async {
    final r = await recheckRecords(), h = RecheckHost();
    final wrong = recheckController(r, h, expectedDigest: 'f' * 64);
    await wrong.load();
    expect(wrong.canRecheck, false);
    wrong.dispose();
    final c = recheckController(r, h);
    await c.load();
    r.values[ImportedCommitCopyRecheckStore.runtimeKey] = 'changed';
    await c.recheck(c.request!);
    expect(h.calls, 0);
    expect(c.result, isNull);
    c.dispose();
  });
  test(
    'durable admission gate revoked before helper entry has zero dispatch',
    () async {
      final r = await recheckRecords(),
          h = RecheckHost(),
          c = recheckController(r, RecheckHost());
      await c.load();
      final live = recheckController(r, h);
      await live.load();
      r.gate = Completer<void>();
      final pending = live.recheck(live.request!);
      await Future<void>.delayed(Duration.zero);
      r.values[ImportedCommitCopyStore.key('/project')] = 'changed';
      r.gate!.complete();
      await pending;
      expect(h.calls, 0);
      expect(live.result, isNull);
      live.dispose();
      c.dispose();
    },
  );
  test('changed current inputs after host completion cannot publish', () async {
    final r = await recheckRecords(), h = RecheckHost();
    final c = recheckController(r, h);
    await c.load();
    h.onRead = (_) =>
        r.values[ImportedCommitCopyRecheckStore.runtimeKey] = 'changed';
    await c.recheck(c.request!);
    expect(h.calls, 1);
    expect(c.result, isNull);
    expect(c.error, isNotNull);
    c.dispose();
  });
  test(
    'Stop retains previous observation as historical and never writes',
    () async {
      final r = await recheckRecords(), h = RecheckHost();
      final c = recheckController(r, h);
      await c.load();
      await c.recheck(c.request!);
      final old = c.result;
      await c.load();
      h.gate = Completer();
      final pending = c.recheck(c.request!);
      await waitUntil(() => h.calls == 2);
      await c.stop();
      await pending;
      expect(c.result, same(old));
      expect(c.resultCurrent, false);
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      c.dispose();
    },
  );
  test('failed retry never relabels previous result as current', () async {
    final r = await recheckRecords(), h = RecheckHost();
    final c = recheckController(r, h);
    await c.load();
    await c.recheck(c.request!);
    final old = c.result;
    await c.load();
    h.fail = true;
    await c.recheck(c.request!);
    expect(c.result, same(old));
    expect(c.resultCurrent, false);
    c.dispose();
  });
  test(
    'disposed read cannot publish and retains lease until owned cleanup',
    () async {
      final r = await recheckRecords(), h = RecheckHost();
      final c = recheckController(r, h);
      await c.load();
      await c.load();
      h.gate = Completer();
      final pending = c.recheck(c.request!);
      await waitUntil(() => h.calls == 1);
      c.dispose();
      await pending;
      expect(c.result, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(ImportedCommitCopyRecheckStore(r).readBusy, false);
    },
  );
  test(
    'uncertain cleanup blocks replacement controller and preserves history',
    () async {
      final r = await recheckRecords(),
          h = RecheckHost()
            ..clean = false
            ..fail = true
            ..failCleanup = true;
      final c = recheckController(r, h);
      await c.load();
      h.clean = true;
      final request = c.request!;
      h.onRead = (_) => h.clean = false;
      await c.recheck(request);
      expect(c.cleanupUncertain, true);
      expect(ImportedCommitCopyRecheckStore(r).readBusy, true);
      final other = recheckController(r, RecheckHost());
      await other.load();
      expect(other.canRecheck, false);
      expect(other.workerBlocked, true);
      other.dispose();
      c.dispose();
    },
  );
  test(
    'a refused read retains the previous completed content observation',
    () async {
      final r = await recheckRecords(), h = RecheckHost();
      final c = recheckController(r, h);
      await c.load();
      await c.recheck(c.request!);
      final previous = c.result;
      await c.load();
      h.status = 'refused';
      await c.recheck(c.request!);
      expect(c.result!.status, ImportedCommitCopyRecheckStatus.refused);
      expect(c.lastObserved, same(previous));
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      c.dispose();
    },
  );
}
