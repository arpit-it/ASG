// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/imported_commit_comparison_controller.dart';
import 'package:asg/models/imported_source_proposal_record.dart';
import 'package:asg/models/imported_source_baseline.dart';
import 'package:asg/models/imported_commit_source_observation.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/imported_commit_source_host.dart';
import 'package:asg/services/imported_commit_comparison_store.dart';
import 'package:asg/services/imported_source_proposal_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/runtime_setup_store.dart';

import 'imported_source_proposal_controller_test.dart' show ProposalRecords;
import 'imported_source_baseline_test.dart' show baselineSaved;
import 'imported_source_baseline_controller_test.dart' as baseline;
import 'imported_commit_comparison_test.dart' show commitObserved;

class CommitHost implements ImportedCommitSourceHost {
  CommitHost(this.saved);
  final ImportedSourceProposalRecord saved;
  @override
  bool supported = true;
  int reads = 0, cancels = 0, disposals = 0;
  Future<ImportedCommitSourceObservation> Function(ImportedCommitReadRequest)?
  onRead;
  Future<void> Function()? onCancel;
  @override
  Future<ImportedCommitSourceObservation> inspect(
    ImportedCommitReadRequest request,
  ) async {
    reads++;
    return onRead == null
        ? commitObserved(saved, commit: request.commit)
        : await onRead!(request);
  }

  @override
  Future<void> cancel() async {
    cancels++;
    await onCancel?.call();
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await cancel();
  }
}

Future<ProposalRecords> baselineRecords(
  ImportedSourceProposalRecord saved,
) async {
  final r = ProposalRecords();
  await InspectedFolderStore(r).save(saved.root);
  await RuntimeSetupStore(r)
      .save(const RuntimeSetup(python: '/trusted/python'));
  r.values[ImportedSourceProposalStore.key(saved.root)] = saved.encode();
  return r;
}

ImportedCommitComparisonController commitController(
  ProposalRecords r,
  CommitHost host,
) => ImportedCommitComparisonController(
  saved: host.saved,
  store: ImportedCommitComparisonStore(r),
  host: host,
)..setCommit('a' * 40);
void main() {
  test('no automatic or unconfirmed read; exact comparison publishes without record writes', () async {
    final saved = baselineSaved(), host = CommitHost(baselineSaved());
    final r = await baselineRecords(saved),
        before = Map<String, String>.of((await baselineRecords(saved)).values);
    final c = commitController(r, host);
    expect(host.reads, 0);
    await c.recheck();
    expect(host.reads, 0);
    await c.recheck(confirm: (_) async => false);
    expect(host.reads, 0);
    final writes = r.writes;
    await c.recheck(
      confirm: (request) async {
        expect(request.root, saved.root);
        expect(request.selectedPaths, ['lib/main.dart', 'test/peer.dart']);
        return true;
      },
    );
    expect(c.comparison!.matched, true);
    expect(c.comparison!.sourceVerified, false);
    expect(c.stale, false);
    expect(r.values, before);
    expect(r.writes, writes);
    expect(r.updatesSeen, everyElement(isEmpty));
    c.dispose();
  });
  for (final moment in ['consent', 'read', 'cleanup']) {
    test(
      'app input changes during $moment retain previous comparison',
      () async {
        final saved = baselineSaved();
        final r = await baselineRecords(saved);
        // Use one owned host to expose each publication boundary deterministically.
        final h = CommitHost(saved), controller = commitController(r, h);
        await controller.recheck(confirm: (_) async => true);
        final previous = controller.comparison;
        final key = ImportedCommitComparisonStore(r)
            .prepare(saved, 'a' * 40)
            .inputs
            .keys
            .last;
        if (moment == 'read') {
          h.onRead = (_) async {
            r.values[key] = 'private changed config';
            return commitObserved(saved, changed: 'test/peer.dart');
          };
        }
        if (moment == 'cleanup') {
          h.onCancel = () async {
            r.values[key] = 'private changed config';
          };
        }
        await controller.recheck(
          confirm: (_) async {
            if (moment == 'consent') r.values[key] = 'private changed config';
            return true;
          },
        );
        expect(controller.comparison, same(previous));
        expect(controller.stale, true);
        expect(controller.error, isNot(contains('private changed config')));
        if (moment == 'consent') expect(h.reads, 1);
        controller.dispose();
      },
    );
  }
  test(
    'all frozen app keys changing during consent prevent dispatch',
    () async {
      final saved = baselineSaved();
      final probe = await baselineRecords(saved);
      final keys = ImportedCommitComparisonStore(probe)
          .prepare(saved, 'a' * 40)
          .inputs
          .keys
          .toList();
      for (final key in keys) {
        final r = await baselineRecords(saved), host = CommitHost(saved);
        final c = commitController(r, host);
        await c.recheck(
          confirm: (_) async {
            r.values[key] = 'changed snapshot';
            return true;
          },
        );
        expect(host.reads, 0);
        expect(c.comparison, isNull);
        expect(c.error, isNotNull);
        c.dispose();
      }
    },
  );
  test(
    'Stop waits for old consent settlement and blocks recreated controller',
    () async {
      final saved = baselineSaved();
      final r = await baselineRecords(saved), host = CommitHost(saved);
      final c = commitController(r, host);
      final consent = Completer<bool>(), entered = Completer<void>();
      final pending = c.recheck(
        confirm: (_) {
          entered.complete();
          return consent.future;
        },
      );
      await entered.future;
      await c.cancel();
      expect(c.busy, true);
      final otherHost = CommitHost(saved),
          other = commitController(r, otherHost);
      await other.recheck(confirm: (_) async => true);
      expect(otherHost.reads, 0);
      expect(other.blockedByOtherRead, true);
      consent.complete(true);
      await pending;
      expect(host.reads, 0);
      expect(c.busy, false);
      await other.recheck(confirm: (_) async => true);
      expect(otherHost.reads, 1);
      c.dispose();
      other.dispose();
    },
  );
  test(
    'late stopped result is dropped while owned cleanup blocks overlap',
    () async {
      final saved = baselineSaved();
      final r = await baselineRecords(saved), host = CommitHost(saved);
      final c = commitController(r, host);
      await c.recheck(confirm: (_) async => true);
      final previous = c.comparison;
      final result = Completer<ImportedCommitSourceObservation>(),
          entered = Completer<void>(),
          cleanup = Completer<void>();
      host.onRead = (_) {
        entered.complete();
        return result.future;
      };
      host.onCancel = () => cleanup.future;
      final pending = c.recheck(confirm: (_) async => true);
      await entered.future;
      final stopping = c.cancel();
      result.complete(commitObserved(saved, changed: 'lib/main.dart'));
      await Future<void>.delayed(Duration.zero);
      expect(c.busy, true);
      expect(c.comparison, same(previous));
      final otherHost = CommitHost(saved),
          other = commitController(r, otherHost);
      await other.recheck(confirm: (_) async => true);
      expect(otherHost.reads, 0);
      cleanup.complete();
      await pending;
      await stopping;
      expect(c.comparison, same(previous));
      expect(c.stale, true);
      expect(c.store.readOwned, false);
      c.dispose();
      other.dispose();
    },
  );
  test(
    'cleanup uncertainty remains blocked across controller recreation',
    () async {
      final saved = baselineSaved();
      final r = await baselineRecords(saved), host = CommitHost(saved);
      final c = commitController(r, host);
      await c.recheck(confirm: (_) async => true);
      final previous = c.comparison;
      host.onCancel = () async => throw StateError('private cleanup');
      await c.recheck(confirm: (_) async => true);
      expect(c.cleanupUncertain, true);
      expect(c.comparison, same(previous));
      expect(c.stale, true);
      expect(c.canRecheck, false);
      c.dispose();
      final otherHost = CommitHost(saved),
          other = commitController(r, otherHost);
      await other.recheck(confirm: (_) async => true);
      expect(otherHost.reads, 0);
      expect(other.blockedByOtherRead, true);
      other.dispose();
    },
  );
  test(
    'disposal drops late reads and releases only after completion cleanup',
    () async {
      final saved = baselineSaved();
      final r = await baselineRecords(saved), host = CommitHost(saved);
      final c = commitController(r, host);
      final result = Completer<ImportedCommitSourceObservation>(),
          entered = Completer<void>();
      host.onRead = (_) {
        entered.complete();
        return result.future;
      };
      final pending = c.recheck(confirm: (_) async => true);
      await entered.future;
      c.dispose();
      final otherHost = CommitHost(saved),
          other = commitController(r, otherHost);
      await other.recheck(confirm: (_) async => true);
      expect(otherHost.reads, 0);
      result.complete(commitObserved(saved));
      await pending;
      expect(c.comparison, isNull);
      expect(c.store.readOwned, false);
      other.dispose();
    },
  );
  test(
    'refused refresh retains previous result with no invented file hashes',
    () async {
      final saved = baselineSaved();
      final r = await baselineRecords(saved), host = CommitHost(saved);
      final c = commitController(r, host);
      await c.recheck(confirm: (_) async => true);
      final previous = c.comparison;
      host.onRead = (request) async => commitObserved(
        saved,
        commit: request.commit,
        reason: 'selected_path_missing',
      );
      await c.recheck(confirm: (_) async => true);
      expect(c.comparison, same(previous));
      expect(c.stale, true);
      expect(c.refusal!.status, ImportedSourceBaselineStatus.refused);
      c.dispose();
    },
  );
  test(
    'editing commit during consent prevents dispatch and preserves history',
    () async {
      final saved = baselineSaved(), host = CommitHost(baselineSaved());
      final records = await baselineRecords(saved);
      final c = commitController(records, host);
      final before = Map<String, String>.of(records.values);
      await c.recheck(
        confirm: (_) async {
          c.setCommit('d' * 40);
          return true;
        },
      );
      expect(host.reads, 0);
      expect(c.comparison, isNull);
      expect(c.busy, false);
      expect(records.values, before);
      c.dispose();
    },
  );
  test(
    'baseline and commit workflows share one pending consent lease',
    () async {
      final saved = baselineSaved(),
          records = await baselineRecords(baselineSaved());
      final baselineHost = baseline.BaselineHost(saved);
      final first = baseline.baselineController(records, baselineHost);
      final entered = Completer<void>(), consent = Completer<bool>();
      final pending = first.recheck(
        confirm: (_) {
          entered.complete();
          return consent.future;
        },
      );
      await entered.future;
      final host = CommitHost(saved);
      final second = commitController(records, host);
      await second.recheck(confirm: (_) async => true);
      expect(second.blockedByOtherRead, true);
      expect(host.reads, 0);
      expect(baselineHost.reads, 0);
      consent.complete(false);
      await pending;
      await second.recheck(confirm: (_) async => true);
      expect(second.comparison!.matched, true);
      first.dispose();
      second.dispose();
    },
  );
  test('helper cleanup uncertainty blocks baseline recreation too', () async {
    final saved = baselineSaved(),
        records = await baselineRecords(baselineSaved()),
        host = CommitHost(baselineSaved());
    host.onRead = (r) async =>
        commitObserved(saved, reason: 'cleanup_uncertain');
    final c = commitController(records, host);
    await c.recheck(confirm: (_) async => true);
    expect(c.cleanupUncertain, true);
    expect(c.canRecheck, false);
    expect(c.comparison, isNull);
    final otherHost = baseline.BaselineHost(saved);
    final other = baseline.baselineController(records, otherHost);
    await other.recheck(confirm: (_) async => true);
    expect(other.blockedByOtherRead, true);
    expect(otherHost.reads, 0);
    c.dispose();
    other.dispose();
  });
}
