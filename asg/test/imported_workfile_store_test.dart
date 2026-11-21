// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/models/imported_index_observation.dart';
import 'package:asg/services/imported_workfile_store.dart';
import 'package:asg/services/imported_index_store.dart';
import 'package:asg/services/inspected_folder_store.dart';

import 'imported_index_controller_test.dart' show indexRecords;
import 'imported_index_observation_test.dart'
    show indexRequest, indexObservationData;

void main() {
  test('two immutable durable inputs verify with zero writes and share index ownership', () async {
    final records = await indexRecords();
    final store = ImportedWorkfileStore(records);
    final r = indexRequest();
    final o = ImportedIndexObservation.fromJson(
      jsonEncode(indexObservationData(r)),
      request: r,
    );
    final selected = store.read(
      root: '/project',
      indexRequest: r,
      indexObservation: o,
      paths: ['lib/main.dart'],
      comparisonId: 'd' * 32,
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
  test(
    'each changed durable input fails both verification and future selection',
    () async {
      for (final key in [
        ImportedWorkfileStore.runtimeKey,
        InspectedFolderStore.key,
      ]) {
        final records = await indexRecords();
        final store = ImportedWorkfileStore(records);
        final r = indexRequest();
        final o = ImportedIndexObservation.fromJson(
          jsonEncode(indexObservationData(r)),
          request: r,
        );
        final selected = store.read(
          root: '/project',
          indexRequest: r,
          indexObservation: o,
          paths: ['lib/main.dart'],
          comparisonId: 'd' * 32,
        );
        records.values[key] = 'changed';
        await expectLater(store.verify(selected, () {}), throwsA(anything));
        expect(
          () => store.read(
            root: '/project',
            indexRequest: r,
            indexObservation: o,
            paths: ['lib/main.dart'],
            comparisonId: 'e' * 32,
          ),
          throwsA(anything),
        );
      }
    },
  );
  test(
    'transaction authorization reruns liveness and cannot mutate records',
    () async {
      final records = await indexRecords();
      final store = ImportedWorkfileStore(records);
      final r = indexRequest();
      final o = ImportedIndexObservation.fromJson(
        jsonEncode(indexObservationData(r)),
        request: r,
      );
      final selected = store.read(
        root: '/project',
        indexRequest: r,
        indexObservation: o,
        paths: ['lib/main.dart'],
        comparisonId: 'd' * 32,
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
