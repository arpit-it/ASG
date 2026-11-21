// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/imported_index_controller.dart';
import 'package:asg/controllers/imported_workfile_controller.dart';
import 'package:asg/models/imported_workfile_comparison.dart';
import 'package:asg/services/imported_workfile_host.dart';
import 'package:asg/services/imported_workfile_store.dart';
import 'package:asg/services/inspected_folder_store.dart';

import 'imported_index_controller_test.dart' as baseline;
import 'imported_commit_proposal_controller_test.dart' show ProposalRecords;
import 'imported_commit_copy_controller_test.dart' show waitUntil;
import 'imported_workfile_comparison_test.dart' show workfileObservationData;

class WorkfileHost implements ImportedWorkfileHost {
  int calls = 0, cancels = 0;
  bool clean = true, available = true, fail = false, failCancel = false;
  Completer<ImportedWorkfileObservation>? gate;
  void Function()? onRead;
  @override
  bool get supported => available;
  @override
  bool get cleanupConfirmed => clean;
  @override
  ImportedWorkfileObservation? get lastObservation => null;
  @override
  Future<ImportedWorkfileObservation> inspect(ImportedWorkfileRequest r) async {
    calls++;
    onRead?.call();
    if (fail) throw StateError('private error');
    return gate == null
        ? ImportedWorkfileObservation.fromJson(
            jsonEncode(workfileObservationData(r)),
            request: r,
          )
        : await gate!.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (failCancel) throw StateError('private cleanup');
    clean = true;
    if (gate != null && !gate!.isCompleted) {
      gate!.completeError(StateError('stopped'));
    }
  }

  @override
  Future<void> dispose() => cancel();
}

Future<ImportedIndexController> readyIndex(ProposalRecords r) async {
  final index = baseline.indexController(r, baseline.IndexHost());
  final request = await index.prepare();
  await index.inspect(request!, confirmed: true);
  expect(index.observationCurrent, true);
  return index;
}

ImportedWorkfileController workfileController(
  ProposalRecords r,
  WorkfileHost h,
  ImportedIndexController index,
) {
  var n = 0;
  return ImportedWorkfileController(
    root: '/project',
    store: ImportedWorkfileStore(r),
    host: h,
    index: index,
    comparisonId: () => (++n).toRadixString(16).padLeft(32, '0'),
  );
}

void main() {
  test(
    'no auto dispatch exact one-use selection consent and zero writes',
    () async {
      final r = await baseline.indexRecords();
      final index = await readyIndex(r);
      final h = WorkfileHost();
      final c = workfileController(r, h, index);
      final before = Map.of(r.values);
      expect(h.calls, 0);
      final first = await c.prepare(['lib/main.dart']);
      expect(h.calls, 0);
      await c.inspect(first!, confirmed: false);
      expect(h.calls, 0);
      final next = await c.prepare(['lib/main.dart']);
      expect(next!.comparisonId, isNot(first.comparisonId));
      await c.inspect(
        ImportedWorkfileRequest.restore(next.requestJson),
        confirmed: true,
      );
      expect(h.calls, 0);
      await c.inspect(next, confirmed: true);
      expect(h.calls, 1);
      expect(c.observationCurrent, true);
      await c.inspect(next, confirmed: true);
      expect(h.calls, 1);
      expect(r.values, before);
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      c.dispose();
      index.dispose();
    },
  );
  test(
    'current index required and unindexed selection never dispatches',
    () async {
      final r = await baseline.indexRecords();
      final index = baseline.indexController(r, baseline.IndexHost());
      final h = WorkfileHost();
      final c = workfileController(r, h, index);
      expect(await c.prepare(['lib/main.dart']), null);
      expect(h.calls, 0);
      final request = await index.prepare();
      await index.inspect(request!, confirmed: true);
      expect(await c.prepare(['lib/missing.dart']), null);
      expect(h.calls, 0);
      c.dispose();
      index.dispose();
    },
  );
  test('replacing or disposing index during consent invalidates exact pending request', () async {
    for (final dispose in [false, true]) {
      final r = await baseline.indexRecords();
      final index = await readyIndex(r);
      final h = WorkfileHost();
      final c = workfileController(r, h, index);
      final request = await c.prepare(['lib/main.dart']);
      if (dispose) {
        index.dispose();
      } else {
        final newer = await index.prepare();
        await index.inspect(newer!, confirmed: true);
      }
      await c.inspect(request!, confirmed: true);
      expect(h.calls, 0);
      expect(c.observationCurrent, false);
      c.dispose();
      if (!dispose) index.dispose();
    }
  });
  test(
    'each durable input changed during consent or dispatch rejects publication',
    () async {
      for (final key in [
        ImportedWorkfileStore.runtimeKey,
        InspectedFolderStore.key,
      ]) {
        for (final duringRead in [false, true]) {
          final r = await baseline.indexRecords();
          final index = await readyIndex(r);
          final h = WorkfileHost();
          final c = workfileController(r, h, index);
          final request = await c.prepare(['lib/main.dart']);
          if (duringRead) {
            h.onRead = () => r.values[key] = 'changed';
          } else {
            r.values[key] = 'changed';
          }
          await c.inspect(request!, confirmed: true);
          expect(h.calls, duringRead ? 1 : 0);
          expect(c.observationCurrent, false);
          expect(c.observation, null);
          expect(c.error, isNot(contains('private')));
          expect(r.updatesSeen.every((m) => m.isEmpty), true);
          c.dispose();
          index.dispose();
        }
      }
    },
  );
  test('synchronous Stop listener blocks process entry without repeated notifications', () async {
    final r = await baseline.indexRecords();
    final index = await readyIndex(r);
    final h = WorkfileHost();
    final c = workfileController(r, h, index);
    final request = await c.prepare(['lib/main.dart']);
    c.addListener(() {
      if (c.canStop) unawaited(c.cancel());
    });
    await c.inspect(request!, confirmed: true);
    expect(h.calls, 0);
    expect(c.observation, null);
    expect(ImportedWorkfileStore(r).readBusy, false);
    c.dispose();
    index.dispose();
  });
  test('pending comparison holds shared source lease through Stop and blocks index reads', () async {
    final r = await baseline.indexRecords();
    final index = await readyIndex(r);
    final h = WorkfileHost()..gate = Completer();
    final c = workfileController(r, h, index);
    final request = await c.prepare(['lib/main.dart']);
    final pending = c.inspect(request!, confirmed: true);
    await waitUntil(() => h.calls == 1);
    expect(await index.prepare(), null);
    expect(ImportedWorkfileStore(r).readBusy, true);
    await c.cancel();
    await pending;
    expect(c.observation, null);
    expect(ImportedWorkfileStore(r).readBusy, false);
    c.dispose();
    index.dispose();
  });
  test('dispose pending comparison excludes late completion and releases only clean ownership', () async {
    final r = await baseline.indexRecords();
    final index = await readyIndex(r);
    final h = WorkfileHost()..gate = Completer();
    final c = workfileController(r, h, index);
    final request = await c.prepare(['lib/main.dart']);
    final pending = c.inspect(request!, confirmed: true);
    await waitUntil(() => h.calls == 1);
    c.dispose();
    await pending;
    await Future<void>.delayed(Duration.zero);
    expect(c.observation, null);
    expect(ImportedWorkfileStore(r).readBusy, false);
    index.dispose();
  });
  test('failed retry retains historical comparison and uncertain cleanup holds ownership', () async {
    final r = await baseline.indexRecords();
    final index = await readyIndex(r);
    final h = WorkfileHost();
    final c = workfileController(r, h, index);
    var request = await c.prepare(['lib/main.dart']);
    await c.inspect(request!, confirmed: true);
    final previous = c.lastObserved;
    request = await c.prepare(['lib/main.dart']);
    h.onRead = () => h.clean = false;
    h.fail = true;
    h.failCancel = true;
    await c.inspect(request!, confirmed: true);
    expect(c.lastObserved, same(previous));
    expect(c.observationCurrent, false);
    expect(c.cleanupUncertain, true);
    expect(await c.prepare(['lib/main.dart']), null);
    expect(ImportedWorkfileStore(r).readBusy, true);
    h.clean = true;
    h.failCancel = false;
    c.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(ImportedWorkfileStore(r).readBusy, false);
    index.dispose();
  });
  test(
    'prepare durable fence after disposal opens no consent or worker',
    () async {
      final r = await baseline.indexRecords();
      final index = await readyIndex(r);
      final h = WorkfileHost();
      final c = workfileController(r, h, index);
      r.gate = Completer();
      final pending = c.prepare(['lib/main.dart']);
      await Future<void>.delayed(Duration.zero);
      c.dispose();
      r.gate!.complete();
      expect(await pending, null);
      expect(h.calls, 0);
      expect(c.confirming, false);
      index.dispose();
    },
  );
}
