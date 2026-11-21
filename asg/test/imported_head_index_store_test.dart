// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_workfile_comparison.dart';
import 'package:asg/services/imported_head_index_store.dart';
import 'package:asg/services/imported_index_store.dart';
import 'package:asg/services/inspected_folder_store.dart';

import 'imported_index_controller_test.dart' show indexRecords;
import 'imported_workfile_comparison_test.dart'
    show workfileRequest, workfileObservationData;

void main() {
  test('immutable durable snapshots verify with zero updates and share index ownership', () async {
    final records = await indexRecords();
    final store = ImportedHeadIndexStore(records);
    final r = workfileRequest();
    final o = ImportedWorkfileObservation.fromJson(
      jsonEncode(workfileObservationData(r)),
      request: r,
    );
    final selected = store.read(
      root: '/project',
      workfileRequest: r,
      workfileObservation: o,
      readId: 'd' * 32,
    );
    final before = Map.of(records.values);
    await store.verify(selected, () {});
    expect(records.values, before);
    expect(records.updatesSeen.every((m) => m.isEmpty), true);
    expect(() => selected.inputs.clear(), throwsUnsupportedError);
    final token = store.acquire();
    expect(ImportedIndexStore(records).readBusy, true);
    expect(() => ImportedIndexStore(records).acquire(), throwsStateError);
    store.requireLease(token);
    store.release(token);
    expect(store.readBusy, false);
    expect(() => store.requireLease(token), throwsStateError);
  });
  test('each changed durable input prevents verification and new snapshot admission', () async {
    for (final key in [
      ImportedHeadIndexStore.runtimeKey,
      InspectedFolderStore.key,
    ]) {
      final records = await indexRecords();
      final store = ImportedHeadIndexStore(records);
      final r = workfileRequest();
      final o = ImportedWorkfileObservation.fromJson(
        jsonEncode(workfileObservationData(r)),
        request: r,
      );
      final selected = store.read(
        root: '/project',
        workfileRequest: r,
        workfileObservation: o,
        readId: 'd' * 32,
      );
      records.values[key] = 'changed';
      await expectLater(store.verify(selected, () {}), throwsA(anything));
      expect(
        () => store.read(
          root: '/project',
          workfileRequest: r,
          workfileObservation: o,
          readId: 'e' * 32,
        ),
        throwsA(anything),
      );
    }
  });
  test(
    'transaction liveness is rerun without changing any app record',
    () async {
      final records = await indexRecords();
      final store = ImportedHeadIndexStore(records);
      final r = workfileRequest();
      final o = ImportedWorkfileObservation.fromJson(
        jsonEncode(workfileObservationData(r)),
        request: r,
      );
      final selected = store.read(
        root: '/project',
        workfileRequest: r,
        workfileObservation: o,
        readId: 'd' * 32,
      );
      var calls = 0;
      await expectLater(
        store.verify(selected, () {
          if (++calls > 1) throw StateError('closed');
        }),
        throwsStateError,
      );
      expect(records.updatesSeen.every((m) => m.isEmpty), true);
    },
  );
}
