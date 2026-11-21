// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/services/imported_index_store.dart';
import 'package:asg/services/imported_commit_copy_store.dart';
import 'package:asg/services/inspected_folder_store.dart';

import 'imported_index_controller_test.dart' show indexRecords;

void main() {
  test('two immutable durable inputs fence without writes and share source ownership', () async {
    final r = await indexRecords(),
        store = ImportedIndexStore(await indexRecords());
    final s = ImportedIndexStore(r),
        selected = ImportedIndexStore(r).read('/project', 'a' * 32);
    final before = Map<String, String>.of(r.values);
    expect(selected.inputs.length, 2);
    expect(() => selected.inputs.clear(), throwsUnsupportedError);
    await s.verify(selected, () {});
    expect(r.values, before);
    expect(r.updatesSeen.every((m) => m.isEmpty), true);
    final token = s.acquire();
    expect(() => ImportedCommitCopyStore(r).acquire(), throwsStateError);
    expect(store.readBusy, false);
    s.release(token);
  });
  test('each changed durable value prevents verification and deleted folder cannot select', () async {
    for (final key in [
      ImportedIndexStore.runtimeKey,
      InspectedFolderStore.key,
    ]) {
      final r = await indexRecords();
      final s = ImportedIndexStore(r),
          selected = ImportedIndexStore(r).read('/project', 'a' * 32);
      r.values[key] = 'changed';
      await expectLater(s.verify(selected, () {}), throwsA(anything));
      expect(r.updatesSeen, isEmpty);
    }
  });
  test(
    'nonce identity changes without restoring approval or creating a record',
    () async {
      final r = await indexRecords(),
          s = ImportedIndexStore(await indexRecords());
      final a = s.read('/project', 'a' * 32), b = s.read('/project', 'b' * 32);
      expect(a.request.matches(b.request), false);
      expect(a.request.authorizesMutation, false);
      expect(r.updatesSeen, isEmpty);
    },
  );
}
