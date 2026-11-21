// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/imported_workfile_controller.dart';
import 'package:asg/controllers/imported_head_index_controller.dart';
import 'package:asg/models/imported_head_index_observation.dart';
import 'package:asg/services/imported_head_index_host.dart';
import 'package:asg/services/imported_head_index_store.dart';
import 'package:asg/services/inspected_folder_store.dart';

import 'imported_index_controller_test.dart' as records;
import 'imported_workfile_controller_test.dart' as previous;
import 'imported_commit_proposal_controller_test.dart' show ProposalRecords;
import 'imported_commit_copy_controller_test.dart' show waitUntil;
import 'imported_head_index_observation_test.dart'
    show headIndexObservationData;

class HeadIndexHost implements ImportedHeadIndexHost {
  int calls = 0, cancels = 0;
  bool clean = true, available = true, fail = false, failCancel = false;
  Completer<ImportedHeadIndexObservation>? gate;
  void Function()? onRead;
  @override
  bool get supported => available;
  @override
  bool get cleanupConfirmed => clean;
  @override
  ImportedHeadIndexObservation? get lastObservation => null;
  @override
  Future<ImportedHeadIndexObservation> inspect(
    ImportedHeadIndexRequest r,
  ) async {
    calls++;
    onRead?.call();
    if (fail) throw StateError('private error');
    return gate == null
        ? ImportedHeadIndexObservation.fromJson(
            jsonEncode(headIndexObservationData(r)),
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

Future<ImportedWorkfileController> readyWorkfile(ProposalRecords r) async {
  final index = await previous.readyIndex(r);
  final workfile = previous.workfileController(
    r,
    previous.WorkfileHost(),
    index,
  );
  final request = await workfile.prepare(['lib/main.dart']);
  await workfile.inspect(request!, confirmed: true);
  expect(workfile.observationCurrent, true);
  return workfile;
}

void closeWorkfile(ImportedWorkfileController c) {
  c.dispose();
  c.index.dispose();
}

ImportedHeadIndexController headIndexController(
  ProposalRecords r,
  HeadIndexHost host,
  ImportedWorkfileController workfile,
) {
  var n = 0;
  return ImportedHeadIndexController(
    root: '/project',
    store: ImportedHeadIndexStore(r),
    host: host,
    workfile: workfile,
    readId: () => (++n).toRadixString(16).padLeft(32, '0'),
  );
}

void main() {
  test('no automatic dispatch cancelled consent and exact single-use read preserve records', () async {
    final r = await records.indexRecords();
    final workfile = await readyWorkfile(r);
    final h = HeadIndexHost();
    final c = headIndexController(r, h, workfile);
    final before = Map.of(r.values);
    expect(h.calls, 0);
    final first = await c.prepare();
    expect(h.calls, 0);
    await c.inspect(first!, confirmed: false);
    expect(h.calls, 0);
    final request = await c.prepare();
    expect(request!.readId, isNot(first.readId));
    expect(request.objectProfile, 'bounded-loose-pack2-index2-v1');
    await c.inspect(
      ImportedHeadIndexRequest.restore(request.requestJson),
      confirmed: true,
    );
    expect(h.calls, 0);
    await c.inspect(request, confirmed: true);
    expect(h.calls, 1);
    expect(c.observationCurrent, true);
    await c.inspect(request, confirmed: true);
    expect(h.calls, 1);
    expect(r.values, before);
    expect(r.updatesSeen.every((m) => m.isEmpty), true);
    c.dispose();
    closeWorkfile(workfile);
  });
  test('a current selected-file comparison is required before any declared-object consent', () async {
    final r = await records.indexRecords();
    final index = await previous.readyIndex(r);
    final workfile = previous.workfileController(
      r,
      previous.WorkfileHost(),
      index,
    );
    final h = HeadIndexHost();
    final c = headIndexController(r, h, workfile);
    expect(await c.prepare(), null);
    expect(h.calls, 0);
    final request = await workfile.prepare(['lib/main.dart']);
    await workfile.inspect(request!, confirmed: true);
    expect(await c.prepare(), isNotNull);
    expect(h.calls, 0);
    c.dispose();
    closeWorkfile(workfile);
  });
  test(
    'new or disposed selected-file evidence invalidates open exact consent',
    () async {
      for (final dispose in [false, true]) {
        final r = await records.indexRecords();
        final workfile = await readyWorkfile(r);
        final h = HeadIndexHost();
        final c = headIndexController(r, h, workfile);
        final request = await c.prepare();
        if (dispose) {
          workfile.dispose();
        } else {
          final next = await workfile.prepare(['lib/main.dart']);
          await workfile.inspect(next!, confirmed: true);
        }
        await c.inspect(request!, confirmed: true);
        expect(h.calls, 0);
        expect(c.observationCurrent, false);
        c.dispose();
        closeWorkfile(workfile);
      }
    },
  );
  test('changed durable runtime or folder before or during dispatch excludes current results', () async {
    for (final key in [
      ImportedHeadIndexStore.runtimeKey,
      InspectedFolderStore.key,
    ]) {
      for (final duringRead in [false, true]) {
        final r = await records.indexRecords();
        final workfile = await readyWorkfile(r);
        final h = HeadIndexHost();
        final c = headIndexController(r, h, workfile);
        final request = await c.prepare();
        if (duringRead) {
          h.onRead = () => r.values[key] = 'changed';
        } else {
          r.values[key] = 'changed';
        }
        await c.inspect(request!, confirmed: true);
        expect(h.calls, duringRead ? 1 : 0);
        expect(c.observation, null);
        expect(c.observationCurrent, false);
        expect(c.error, isNot(contains('private')));
        expect(r.updatesSeen.every((m) => m.isEmpty), true);
        c.dispose();
        closeWorkfile(workfile);
      }
    }
  });
  test(
    'synchronous Stop listener prevents startup and remains idempotent',
    () async {
      final r = await records.indexRecords();
      final workfile = await readyWorkfile(r);
      final h = HeadIndexHost();
      final c = headIndexController(r, h, workfile);
      final request = await c.prepare();
      c.addListener(() {
        if (c.canStop) unawaited(c.cancel());
      });
      await c.inspect(request!, confirmed: true);
      expect(h.calls, 0);
      expect(c.observation, null);
      expect(ImportedHeadIndexStore(r).readBusy, false);
      c.dispose();
      closeWorkfile(workfile);
    },
  );
  test(
    'shared ownership blocks upstream work until Stop cleanup settles',
    () async {
      final r = await records.indexRecords();
      final workfile = await readyWorkfile(r);
      final h = HeadIndexHost()..gate = Completer();
      final c = headIndexController(r, h, workfile);
      final request = await c.prepare();
      final pending = c.inspect(request!, confirmed: true);
      await waitUntil(() => h.calls == 1);
      expect(await workfile.prepare(['lib/main.dart']), null);
      expect(await workfile.index.prepare(), null);
      expect(ImportedHeadIndexStore(r).readBusy, true);
      await c.cancel();
      await pending;
      expect(c.observation, null);
      expect(ImportedHeadIndexStore(r).readBusy, false);
      c.dispose();
      closeWorkfile(workfile);
    },
  );
  test('disposal during read suppresses late result and releases only confirmed ownership', () async {
    final r = await records.indexRecords();
    final workfile = await readyWorkfile(r);
    final h = HeadIndexHost()..gate = Completer();
    final c = headIndexController(r, h, workfile);
    final request = await c.prepare();
    final pending = c.inspect(request!, confirmed: true);
    await waitUntil(() => h.calls == 1);
    c.dispose();
    await pending;
    await Future<void>.delayed(Duration.zero);
    expect(c.observation, null);
    expect(ImportedHeadIndexStore(r).readBusy, false);
    closeWorkfile(workfile);
  });
  test('failed retry preserves dated history and uncertain cleanup holds the source lease', () async {
    final r = await records.indexRecords();
    final workfile = await readyWorkfile(r);
    final h = HeadIndexHost();
    final c = headIndexController(r, h, workfile);
    var request = await c.prepare();
    await c.inspect(request!, confirmed: true);
    final previous = c.lastObserved;
    request = await c.prepare();
    h.onRead = () => h.clean = false;
    h.fail = true;
    h.failCancel = true;
    await c.inspect(request!, confirmed: true);
    expect(c.lastObserved, same(previous));
    expect(c.observationCurrent, false);
    expect(c.cleanupUncertain, true);
    expect(await c.prepare(), null);
    expect(ImportedHeadIndexStore(r).readBusy, true);
    h.clean = true;
    h.failCancel = false;
    c.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(ImportedHeadIndexStore(r).readBusy, false);
    closeWorkfile(workfile);
  });
  test(
    'durable preparation that finishes after disposal cannot open consent',
    () async {
      final r = await records.indexRecords();
      final workfile = await readyWorkfile(r);
      final h = HeadIndexHost();
      final c = headIndexController(r, h, workfile);
      r.gate = Completer();
      final pending = c.prepare();
      await Future<void>.delayed(Duration.zero);
      c.dispose();
      r.gate!.complete();
      expect(await pending, null);
      expect(h.calls, 0);
      expect(c.confirming, false);
      closeWorkfile(workfile);
    },
  );
}
