// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/imported_source_baseline_controller.dart';
import 'package:asg/models/imported_source_proposal_record.dart';
import 'package:asg/models/imported_source_baseline.dart';
import 'package:asg/models/project_source_observation.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/project_source_host.dart';
import 'package:asg/services/imported_source_baseline_store.dart';
import 'package:asg/services/imported_source_proposal_store.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/runtime_setup_store.dart';

import 'imported_source_proposal_controller_test.dart' show ProposalRecords;
import 'imported_source_baseline_test.dart'
    show baselineSaved, baselineObserved;

class BaselineHost implements ProjectSourceHost {
  BaselineHost(this.saved);
  final ImportedSourceProposalRecord saved;
  @override
  bool supported = true;
  int reads = 0, cancels = 0, disposals = 0;
  Future<ProjectSourceObservation> Function(ProjectSourceReadRequest)? onRead;
  Future<void> Function()? onCancel;
  @override
  Future<ProjectSourceObservation> inspect(
    ProjectSourceReadRequest request,
  ) async {
    reads++;
    return onRead == null ? baselineObserved(saved) : await onRead!(request);
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

ImportedSourceBaselineController baselineController(
  ProposalRecords r,
  BaselineHost host,
) => ImportedSourceBaselineController(
  saved: host.saved,
  store: ImportedSourceBaselineStore(r),
  host: host,
);
void main() {
  test('no automatic or unconfirmed read; exact comparison publishes without record writes', () async {
    final saved = baselineSaved(), host = BaselineHost(baselineSaved());
    final r = await baselineRecords(saved),
        before = Map<String, String>.of((await baselineRecords(saved)).values);
    final c = baselineController(r, host);
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
        final h = BaselineHost(saved), controller = baselineController(r, h);
        await controller.recheck(confirm: (_) async => true);
        final previous = controller.comparison;
        final key = ImportedSourceBaselineStore(r)
            .prepare(saved)
            .inputs
            .keys
            .last;
        if (moment == 'read') {
          h.onRead = (_) async {
            r.values[key] = 'private changed config';
            return baselineObserved(saved, changed: 'test/peer.dart');
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
      final keys = ImportedSourceBaselineStore(probe)
          .prepare(saved)
          .inputs
          .keys
          .toList();
      for (final key in keys) {
        final r = await baselineRecords(saved), host = BaselineHost(saved);
        final c = baselineController(r, host);
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
      final r = await baselineRecords(saved), host = BaselineHost(saved);
      final c = baselineController(r, host);
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
      final otherHost = BaselineHost(saved),
          other = baselineController(r, otherHost);
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
      final r = await baselineRecords(saved), host = BaselineHost(saved);
      final c = baselineController(r, host);
      await c.recheck(confirm: (_) async => true);
      final previous = c.comparison;
      final result = Completer<ProjectSourceObservation>(),
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
      result.complete(baselineObserved(saved, changed: 'lib/main.dart'));
      await Future<void>.delayed(Duration.zero);
      expect(c.busy, true);
      expect(c.comparison, same(previous));
      final otherHost = BaselineHost(saved),
          other = baselineController(r, otherHost);
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
      final r = await baselineRecords(saved), host = BaselineHost(saved);
      final c = baselineController(r, host);
      await c.recheck(confirm: (_) async => true);
      final previous = c.comparison;
      host.onCancel = () async => throw StateError('private cleanup');
      await c.recheck(confirm: (_) async => true);
      expect(c.cleanupUncertain, true);
      expect(c.comparison, same(previous));
      expect(c.stale, true);
      expect(c.canRecheck, false);
      c.dispose();
      final otherHost = BaselineHost(saved),
          other = baselineController(r, otherHost);
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
      final r = await baselineRecords(saved), host = BaselineHost(saved);
      final c = baselineController(r, host);
      final result = Completer<ProjectSourceObservation>(),
          entered = Completer<void>();
      host.onRead = (_) {
        entered.complete();
        return result.future;
      };
      final pending = c.recheck(confirm: (_) async => true);
      await entered.future;
      c.dispose();
      final otherHost = BaselineHost(saved),
          other = baselineController(r, otherHost);
      await other.recheck(confirm: (_) async => true);
      expect(otherHost.reads, 0);
      result.complete(baselineObserved(saved));
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
      final r = await baselineRecords(saved), host = BaselineHost(saved);
      final c = baselineController(r, host);
      await c.recheck(confirm: (_) async => true);
      final previous = c.comparison;
      host.onRead = (request) async => ProjectSourceObservation.fromJson(
        jsonEncode({
          'version': 1,
          'scope': 'project-source-files',
          'status': 'invalid',
          'reason': 'source_missing',
          'selected_paths': request.selectedPaths,
          'files': [],
          'source_verified': false,
        }),
      );
      await c.recheck(confirm: (_) async => true);
      expect(c.comparison, same(previous));
      expect(c.stale, true);
      expect(c.refusal!.status, ImportedSourceBaselineStatus.refused);
      c.dispose();
    },
  );
}
