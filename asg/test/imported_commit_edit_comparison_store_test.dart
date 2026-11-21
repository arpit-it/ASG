// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/services/imported_commit_edit_comparison_store.dart';
import 'package:asg/services/imported_commit_copy_store.dart';
import 'package:asg/services/imported_commit_edit_store.dart';
import 'package:asg/services/inspected_folder_store.dart';

import 'imported_commit_edit_comparison_controller_test.dart'
    show comparisonRecords;

void main() {
  test(
    'four durable identities fence without writes and share source lease',
    () async {
      final r = await comparisonRecords(),
          s = ImportedCommitEditComparisonStore(await comparisonRecords());
      final store = ImportedCommitEditComparisonStore(r),
          selected = ImportedCommitEditComparisonStore(r)
              .read('/project', 'a' * 32);
      expect(selected.inputs.length, 4);
      await store.verify(selected, () {});
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      expect(() => selected.inputs.clear(), throwsUnsupportedError);
      final token = store.acquire();
      expect(s.readBusy, false);
      expect(store.readBusy, true);
      expect(() => store.acquire(), throwsStateError);
      store.release(token);
    },
  );
  test(
    'each changed durable input revokes read admission without effects',
    () async {
      for (final key in [
        ImportedCommitCopyStore.key('/project'),
        ImportedCommitEditStore.key('/project'),
        ImportedCommitEditComparisonStore.runtimeKey,
        InspectedFolderStore.key,
      ]) {
        final r = await comparisonRecords(),
            s = ImportedCommitEditComparisonStore(await comparisonRecords());
        final store = ImportedCommitEditComparisonStore(r),
            selected = ImportedCommitEditComparisonStore(r)
                .read('/project', 'a' * 32);
        r.values[key] = 'changed';
        await expectLater(store.verify(selected, () {}), throwsA(anything));
        expect(r.updatesSeen, isEmpty);
        expect(
          () =>
              s.read('/project', 'a' * 32, expectedEditHistoryDigest: 'f' * 64),
          throwsStateError,
        );
      }
    },
  );
}
