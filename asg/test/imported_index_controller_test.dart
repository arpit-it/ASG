// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/imported_index_controller.dart';
import 'package:asg/models/imported_index_observation.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/imported_index_host.dart';
import 'package:asg/services/imported_index_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/runtime_setup_store.dart';

import 'imported_commit_proposal_controller_test.dart' show ProposalRecords;
import 'imported_commit_copy_controller_test.dart' show waitUntil;
import 'imported_index_observation_test.dart' show indexObservationData;

Future<ProposalRecords> indexRecords() async {
  final r = ProposalRecords();
  await InspectedFolderStore(r).save('/project');
  await RuntimeSetupStore(r)
      .save(const RuntimeSetup(python: '/trusted/python'));
  r.updatesSeen.clear();
  return r;
}

class IndexHost implements ImportedIndexHost {
  int calls = 0, cancels = 0;
  bool clean = true, available = true, fail = false, failCancel = false;
  Completer<ImportedIndexObservation>? gate;
  void Function()? onRead;
  @override
  bool get supported => available;
  @override
  bool get cleanupConfirmed => clean;
  @override
  ImportedIndexObservation? get lastObservation => null;
  @override
  Future<ImportedIndexObservation> inspect(ImportedIndexReadRequest r) async {
    calls++;
    onRead?.call();
    if (fail) throw StateError('private reader error');
    return gate == null
        ? ImportedIndexObservation.fromJson(
            jsonEncode(indexObservationData(r)),
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

ImportedIndexController indexController(
  ProposalRecords records,
  IndexHost host,
) {
  var n = 0;
  return ImportedIndexController(
    root: '/project',
    store: ImportedIndexStore(records),
    host: host,
    readId: () => (++n).toRadixString(16).padLeft(32, '0'),
  );
}

void main() {
  test('prepare and cancelled consent never dispatch; exact single-use consent has only read-only fences', () async {
    final r = await indexRecords(), h = IndexHost();
    final c = indexController(r, h), before = Map<String, String>.of(r.values);
    expect(h.calls, 0);
    final first = await c.prepare();
    expect(h.calls, 0);
    expect(c.confirming, true);
    await c.inspect(first!, confirmed: false);
    expect(h.calls, 0);
    final second = await c.prepare();
    expect(second!.readId, isNot(first.readId));
    await c.inspect(
      ImportedIndexReadRequest.restore(second.requestJson),
      confirmed: true,
    );
    expect(h.calls, 0);
    await c.inspect(second, confirmed: true);
    expect(h.calls, 1);
    expect(c.observationCurrent, true);
    expect(c.observation!.authorizesCommit, false);
    await c.inspect(second, confirmed: true);
    expect(h.calls, 1);
    expect(r.values, before);
    expect(r.updatesSeen.every((m) => m.isEmpty), true);
    c.dispose();
  });
  test(
    'runtime or inspected-folder change while consent is open prevents startup',
    () async {
      for (final key in [
        ImportedIndexStore.runtimeKey,
        InspectedFolderStore.key,
      ]) {
        final r = await indexRecords(), h = IndexHost();
        final c = indexController(r, h);
        final request = await c.prepare();
        r.values[key] = 'changed';
        await c.inspect(request!, confirmed: true);
        expect(h.calls, 0);
        expect(c.observationCurrent, false);
        expect(c.error, isNot(contains('private')));
        c.dispose();
      }
    },
  );
  test(
    'completion rereads both durable inputs before publishing any observation',
    () async {
      for (final key in [
        ImportedIndexStore.runtimeKey,
        InspectedFolderStore.key,
      ]) {
        final r = await indexRecords(), h = IndexHost();
        final c = indexController(r, h);
        final request = await c.prepare();
        h.onRead = () => r.values[key] = 'changed';
        await c.inspect(request!, confirmed: true);
        expect(h.calls, 1);
        expect(c.observation, isNull);
        expect(c.observationCurrent, false);
        expect(r.updatesSeen.every((m) => m.isEmpty), true);
        c.dispose();
      }
    },
  );
  test('Stop from busy listener prevents process entry and releases its shared lease', () async {
    final r = await indexRecords(), h = IndexHost();
    final c = indexController(r, h);
    final request = await c.prepare();
    c.addListener(() {
      if (c.canStop) unawaited(c.cancel());
    });
    await c.inspect(request!, confirmed: true);
    expect(h.calls, 0);
    expect(c.observation, isNull);
    expect(ImportedIndexStore(r).readBusy, false);
    c.dispose();
  });
  test('in-flight read owns shared source lease until Stop settles', () async {
    final r = await indexRecords(), h = IndexHost()..gate = Completer();
    final c = indexController(r, h);
    final request = await c.prepare();
    final pending = c.inspect(request!, confirmed: true);
    await waitUntil(() => h.calls == 1);
    final other = indexController(r, IndexHost());
    expect(await other.prepare(), isNull);
    expect(ImportedIndexStore(r).readBusy, true);
    await c.cancel();
    await pending;
    expect(c.observation, isNull);
    expect(ImportedIndexStore(r).readBusy, false);
    c.dispose();
    other.dispose();
  });
  test('dispose while pending cannot promote a late result', () async {
    final r = await indexRecords(), h = IndexHost()..gate = Completer();
    final c = indexController(r, h);
    final request = await c.prepare();
    final pending = c.inspect(request!, confirmed: true);
    await waitUntil(() => h.calls == 1);
    c.dispose();
    await pending;
    await Future<void>.delayed(Duration.zero);
    expect(c.observation, isNull);
    expect(ImportedIndexStore(r).readBusy, false);
  });
  test('failed retry retains prior dated evidence and unknown cleanup blocks new reads', () async {
    final r = await indexRecords(), h = IndexHost();
    final c = indexController(r, h);
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
    expect(ImportedIndexStore(r).readBusy, true);
    expect(await c.prepare(), isNull);
    h.clean = true;
    h.failCancel = false;
    c.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(ImportedIndexStore(r).readBusy, false);
  });
  test(
    'prepare fence that settles after disposal never opens consent or a worker',
    () async {
      final r = await indexRecords(), h = IndexHost();
      r.gate = Completer();
      final c = indexController(r, h);
      final pending = c.prepare();
      await Future<void>.delayed(Duration.zero);
      c.dispose();
      r.gate!.complete();
      expect(await pending, isNull);
      expect(h.calls, 0);
      expect(c.confirming, false);
    },
  );
}
