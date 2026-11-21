// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/services/imported_commit_copy_recheck_store.dart';
import 'package:asg/services/imported_commit_copy_store.dart';
import 'package:asg/models/imported_commit_copy_request.dart';

import 'imported_commit_copy_recheck_controller_test.dart' show recheckRecords;
import 'imported_commit_copy_recheck_test.dart' show preparedCopyHistory;

void main() {
  test(
    'saved history runtime and registration fence with zero writes',
    () async {
      final r = await recheckRecords(),
          s = ImportedCommitCopyRecheckStore(await recheckRecords());
      final store = ImportedCommitCopyRecheckStore(r);
      final selected = store.read('/project', 'a' * 32);
      expect(selected.inputs.length, 3);
      await store.verify(selected, () {});
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      expect(() => selected.inputs.clear(), throwsUnsupportedError);
      final token = store.acquire();
      expect(s.readBusy, false);
      expect(store.readBusy, true);
      expect(() => store.acquire(), throwsStateError);
      store.release(token);
      expect(store.readBusy, false);
    },
  );
  test(
    'missing corrupt and unresolved history refuse without effects',
    () async {
      final r = await recheckRecords(),
          s = ImportedCommitCopyRecheckStore(await recheckRecords());
      expect(
        () => s.read('/project', 'a' * 32, expectedHistoryDigest: 'f' * 64),
        throwsStateError,
      );
      final store = ImportedCommitCopyRecheckStore(r),
          key = ImportedCommitCopyStore.key('/project');
      final prepared = preparedCopyHistory();
      final next = ImportedCommitCopyRequest.restore(
        prepared.lastPrepared!.request.requestJson.replaceFirst(
          'a' * 32,
          'c' * 32,
        ),
      );
      for (final value in [
        null,
        'private',
        prepared.begin(next, DateTime.utc(2026)).recordJson,
      ]) {
        if (value == null) {
          r.values.remove(key);
        } else {
          r.values[key] = value;
        }
        expect(() => store.read('/project', 'a' * 32), throwsA(anything));
      }
      expect(r.updatesSeen, isEmpty);
    },
  );
}
