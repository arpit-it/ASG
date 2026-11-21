// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/services/imported_dart_diagnostics_store.dart';
import 'package:asg/services/imported_commit_copy_store.dart';
import 'package:asg/services/imported_commit_edit_store.dart';
import 'package:asg/services/imported_commit_edit_comparison_store.dart';
import 'package:asg/services/inspected_folder_store.dart';

import 'imported_commit_edit_comparison_controller_test.dart'
    show comparisonRecords, comparisonResult;
import 'imported_dart_diagnostics_controller_test.dart' show diagnosticSdk;

void main() {
  test('selection joins current comparison and SDK without changing four durable records', () async {
    final r = await comparisonRecords(),
        s = ImportedDartDiagnosticsStore(await comparisonRecords());
    final c = ImportedCommitEditComparisonStore(r)
        .read('/project', 'a' * 32)
        .request;
    final store = ImportedDartDiagnosticsStore(r),
        selected = ImportedDartDiagnosticsStore(r)
            .select(c, comparisonResult(c));
    final before = Map<String, String>.of(r.values);
    await store.verify(selected, () {});
    final request = store.request(
      selected: selected,
      observation: comparisonResult(c),
      sdk: diagnosticSdk(),
      runId: 'e' * 32,
    );
    expect(request.comparison.matches(c), true);
    expect(request.verifiesProject, false);
    expect(selected.inputs.length, 4);
    expect(r.values, before);
    expect(r.updatesSeen.every((m) => m.isEmpty), true);
    final token = store.acquire();
    expect(store.readBusy, true);
    expect(s.readBusy, false);
    expect(() => ImportedCommitCopyStore(r).acquire(), throwsStateError);
    store.release(token);
  });
  test(
    'each changed input prevents verified selection and request admission',
    () async {
      for (final key in [
        ImportedCommitCopyStore.key('/project'),
        ImportedCommitEditStore.key('/project'),
        ImportedCommitEditComparisonStore.runtimeKey,
        InspectedFolderStore.key,
      ]) {
        final r = await comparisonRecords();
        final c = ImportedCommitEditComparisonStore(r)
            .read('/project', 'a' * 32)
            .request;
        final store = ImportedDartDiagnosticsStore(r),
            selected = ImportedDartDiagnosticsStore(r)
                .select(c, comparisonResult(c));
        r.values[key] = 'changed';
        await expectLater(store.verify(selected, () {}), throwsA(anything));
        expect(
          () => store.request(
            selected: selected,
            observation: comparisonResult(c),
            sdk: diagnosticSdk(),
            runId: 'e' * 32,
          ),
          throwsA(anything),
        );
        expect(r.updatesSeen, isEmpty);
      }
    },
  );
  test(
    'different comparison nonce and changed or refused evidence cannot admit',
    () async {
      final r = await comparisonRecords(),
          store = ImportedDartDiagnosticsStore(await comparisonRecords());
      final c = ImportedCommitEditComparisonStore(r)
          .read('/project', 'a' * 32)
          .request;
      final other = ImportedCommitEditComparisonStore(r)
          .read('/project', 'b' * 32)
          .request;
      expect(
        () => store.select(c, comparisonResult(other)),
        throwsFormatException,
      );
      for (final status in ['changed', 'refused']) {
        expect(
          () => store.select(c, comparisonResult(c, status: status)),
          throwsStateError,
        );
      }
    },
  );
}
