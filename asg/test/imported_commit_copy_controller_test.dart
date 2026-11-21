// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/imported_commit_copy_controller.dart';
import 'package:asg/models/imported_commit_copy_request.dart';
import 'package:asg/models/imported_commit_copy_record.dart';
import 'package:asg/models/imported_commit_copy_observation.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/imported_commit_copy_host.dart';
import 'package:asg/services/imported_commit_copy_store.dart';
import 'package:asg/services/imported_plan_store.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:flutter_test/flutter_test.dart';

import 'imported_commit_proposal_controller_test.dart' as proposal;
import 'imported_plan_test.dart' show finding;
import 'imported_commit_copy_observation_test.dart' show copyObservationData;

class CopyRecords extends proposal.ProposalRecords {
  Completer<void>? admissionGate, completionGate, acknowledgementGate;
  void Function(ImportedCommitCopyRecord)? afterCopyWrite;
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    void Function()? authorize,
  }) async {
    final raw = updates[ImportedCommitCopyStore.key('/project')];
    final record = raw == null ? null : ImportedCommitCopyRecord.decode(raw);
    if (record?.latest?.phase == ImportedCommitCopyPhase.pending) {
      await admissionGate?.future;
    }
    if (record?.latest?.phase == ImportedCommitCopyPhase.prepared) {
      await completionGate?.future;
    }
    if (record?.latest?.acknowledgedAt != null) {
      await acknowledgementGate?.future;
    }
    await super.commitRecords(
      expected: expected,
      updates: updates,
      authorize: authorize,
    );
    if (record != null) afterCopyWrite?.call(record);
  }
}

Future<CopyRecords> copyRecords() async {
  final initial = await proposal.proposalRecords();
  final r = CopyRecords();
  r.values.addAll(initial.values);
  final c = proposal.proposalController(r);
  await c.load();
  await c.preview('lib/main.dart', '// proposed replacement');
  await c.save(c.proposal!);
  c.dispose();
  await RuntimeSetupStore(r)
      .save(const RuntimeSetup(python: '/trusted/python'));
  r.updatesSeen.clear();
  return r;
}

class CopyHost implements ImportedCommitCopyHost {
  int calls = 0, cancels = 0;
  bool supportedValue = true, clean = true, fail = false, failCleanup = false;
  Completer<ImportedCommitCopyObservation>? gate;
  void Function(ImportedCommitCopyRequest)? onPrepare;
  ImportedCommitCopyObservation? last;
  @override
  bool get supported => supportedValue;
  @override
  bool get cleanupConfirmed => clean;
  @override
  ImportedCommitCopyObservation? get lastObservation => last;
  @override
  Future<ImportedCommitCopyObservation> prepare(
    ImportedCommitCopyRequest request,
  ) async {
    calls++;
    onPrepare?.call(request);
    if (fail) throw StateError('private helper failure');
    final value = gate == null
        ? ImportedCommitCopyObservation.fromJson(
            jsonEncode(copyObservationData(request)),
            request: request,
          )
        : await gate!.future;
    last = value;
    return value;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (failCleanup) throw StateError('private cleanup failure');
    clean = true;
    if (gate != null && !gate!.isCompleted) {
      gate!.completeError(StateError('stopped'));
    }
  }

  @override
  Future<void> dispose() => cancel();
}

ImportedCommitCopyController copyController(
  CopyRecords r,
  CopyHost host, {
  DateTime Function()? clock,
}) {
  var nonce = 0;
  return ImportedCommitCopyController(
    root: '/project',
    inspection: finding(),
    store: ImportedCommitCopyStore(r),
    host: host,
    clock: clock ?? () => DateTime.utc(2026),
    attemptId: () => (++nonce).toRadixString(16).padLeft(32, '0'),
  );
}

Future<void> waitUntil(bool Function() condition) async {
  for (var i = 0; i < 100; i++) {
    if (condition()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('Expected owned fixture boundary was not reached.');
}

class DeferredCopyPicker extends FolderPicker {
  final gate = Completer<String?>();
  @override
  bool get supported => true;
  @override
  Future<String?> pick() => gate.future;
}

void main() {
  test(
    'closed or replaced destination picker cannot return an actionable path',
    () async {
      final r = await copyRecords(),
          host = CopyHost(),
          picker = DeferredCopyPicker();
      final c = ImportedCommitCopyController(
        root: '/project',
        inspection: finding(),
        store: ImportedCommitCopyStore(r),
        host: host,
        picker: picker,
      );
      await c.load();
      final picked = c.pickDestination();
      await Future<void>.delayed(Duration.zero);
      c.dispose();
      picker.gate.complete('/copies');
      expect(await picked, isNull);
      expect(c.draft, isNull);
      expect(host.calls, 0);
      expect(r.values[ImportedCommitCopyStore.key('/project')], isNull);
    },
  );
  test('selected history digest and workspace root cannot silently retarget a copy', () async {
    final r = await copyRecords();
    for (final root in ['/project', '/other']) {
      final host = CopyHost();
      final c = ImportedCommitCopyController(
        root: root,
        inspection: finding(),
        expectedHistoryDigest: 'f' * 64,
        store: ImportedCommitCopyStore(r),
        host: host,
      );
      await c.load();
      expect(c.canReview, false);
      expect(c.currentProposal, isNull);
      expect(host.calls, 0);
      c.dispose();
    }
  });
  test('review has no writes; durable pending intent and fence precede helper entry', () async {
    final r = await copyRecords(), host = CopyHost();
    final c = copyController(r, host);
    await c.load();
    await c.review('/copies');
    expect(r.updatesSeen, everyElement(isEmpty));
    expect(host.calls, 0);
    host.onPrepare = (request) {
      final saved = ImportedCommitCopyRecord.decode(
        r.values[ImportedCommitCopyStore.key('/project')]!,
      );
      expect(saved.latest!.phase, ImportedCommitCopyPhase.pending);
      expect(saved.latest!.request.digest, request.digest);
    };
    await c.prepare(c.draft!);
    expect(host.calls, 1);
    expect(c.history!.lastPrepared, isNotNull);
    expect(c.error, isNull);
    expect(c.canPrepare, false);
    c.dispose();
  });
  test('failed and lost admission confirmation never dispatch and pending restart blocks replay', () async {
    for (final lost in [false, true]) {
      final r = await copyRecords(), host = CopyHost();
      final c = copyController(r, host);
      await c.load();
      await c.review('/copies');
      if (lost) {
        r.afterCopyWrite = (value) {
          if (value.latest!.phase == ImportedCommitCopyPhase.pending) {
            throw StateError('lost admission confirmation');
          }
        };
      } else {
        r.failWrites = true;
      }
      await c.prepare(c.draft!);
      expect(host.calls, 0);
      expect(c.error, isNotNull);
      r.afterCopyWrite = null;
      r.failWrites = false;
      c.dispose();
      final reopened = copyController(r, CopyHost());
      await reopened.load();
      expect(reopened.history!.needsRecovery, lost);
      expect(reopened.canPrepare, false);
      reopened.dispose();
    }
  });
  test('changed input after admission prevents dispatch and retains unconfirmed intent', () async {
    final r = await copyRecords(), host = CopyHost();
    final c = copyController(r, host);
    await c.load();
    await c.review('/copies');
    r.afterCopyWrite = (record) {
      if (record.latest!.phase == ImportedCommitCopyPhase.pending) {
        r.values.remove(ImportedPlanStore.key('/project'));
      }
    };
    await c.prepare(c.draft!);
    expect(host.calls, 0);
    expect(c.canPrepare, false);
    expect(c.error, isNotNull);
    final durable = ImportedCommitCopyRecord.decode(
      r.values[ImportedCommitCopyStore.key('/project')]!,
    );
    expect(durable.latest!.phase, ImportedCommitCopyPhase.pending);
    await c.load();
    expect(c.history!.needsRecovery, true);
    c.dispose();
  });
  test(
    'changed plan after helper entry retains receipt only as recovery evidence',
    () async {
      final r = await copyRecords(), host = CopyHost();
      host.gate = Completer();
      final c = copyController(r, host);
      await c.load();
      await c.review('/copies');
      final request = c.draft!;
      final pending = c.prepare(request);
      await waitUntil(() => host.calls == 1);
      r.values.remove(ImportedPlanStore.key('/project'));
      host.gate!.complete(
        ImportedCommitCopyObservation.fromJson(
          jsonEncode(copyObservationData(request)),
          request: request,
        ),
      );
      await pending;
      expect(c.history!.latest!.phase, ImportedCommitCopyPhase.unconfirmed);
      expect(c.history!.lastPrepared, isNull);
      expect(c.history!.latest!.observation, isNotNull);
      expect(c.canPrepare, false);
      c.dispose();
    },
  );
  test(
    'Stop and disposal during helper work cannot promote late success',
    () async {
      for (final dispose in [false, true]) {
        final r = await copyRecords(), host = CopyHost();
        host.gate = Completer();
        final c = copyController(r, host);
        await c.load();
        await c.review('/copies');
        final pending = c.prepare(c.draft!);
        await waitUntil(() => host.calls == 1);
        if (dispose) {
          c.dispose();
        } else {
          await c.stop();
        }
        await pending;
        final saved = ImportedCommitCopyRecord.decode(
          r.values[ImportedCommitCopyStore.key('/project')]!,
        );
        expect(saved.lastPrepared, isNull);
        expect(saved.needsRecovery, true);
        expect(host.clean, true);
        if (dispose) {
          expect(c.reported, isNull);
        } else {
          c.dispose();
        }
      }
    },
  );
  test(
    'disposal while admission waits prevents write and helper startup',
    () async {
      final r = await copyRecords(), host = CopyHost();
      final c = copyController(r, host);
      await c.load();
      await c.review('/copies');
      r.admissionGate = Completer();
      final pending = c.prepare(c.draft!);
      await Future<void>.delayed(Duration.zero);
      c.dispose();
      r.admissionGate!.complete();
      await pending;
      expect(host.calls, 0);
      expect(r.values[ImportedCommitCopyStore.key('/project')], isNull);
    },
  );
  test('lost completion confirmation preserves current UI until explicit history reload', () async {
    final r = await copyRecords(), host = CopyHost();
    final c = copyController(r, host);
    await c.load();
    await c.review('/copies');
    r.afterCopyWrite = (record) {
      if (record.latest!.phase == ImportedCommitCopyPhase.prepared) {
        throw StateError('lost completion confirmation');
      }
    };
    await c.prepare(c.draft!);
    expect(c.history!.lastPrepared, isNull);
    expect(c.error, isNotNull);
    expect(host.calls, 1);
    r.afterCopyWrite = null;
    await c.load();
    expect(c.history!.lastPrepared, isNotNull);
    expect(c.canPrepare, false);
    expect(host.calls, 1);
    c.dispose();
  });
  test('operator acknowledgement neither replays nor promotes; foreign dialog snapshots refuse', () async {
    final r = await copyRecords(), host = CopyHost();
    host.fail = true;
    final c = copyController(r, host);
    await c.load();
    await c.review('/copies');
    await c.prepare(c.draft!);
    final old = c.history!;
    expect(old.needsRecovery, true);
    await c.acknowledge(old, inspectedAndStopped: false);
    expect(c.history!.needsRecovery, true);
    await c.acknowledge(
      ImportedCommitCopyRecord.decode(old.recordJson),
      inspectedAndStopped: true,
    );
    expect(c.history!.needsRecovery, true);
    await c.acknowledge(old, inspectedAndStopped: true);
    expect(c.history!.needsRecovery, false);
    expect(c.history!.lastPrepared, isNull);
    expect(host.calls, 1);
    expect(c.canReview, false);
    await c.load();
    expect(c.canReview, true);
    expect(c.canPrepare, false);
    c.dispose();
  });
  test('local recovery acknowledgement does not advertise an ineffective Stop copy', () async {
    final r = await copyRecords(), host = CopyHost();
    host.fail = true;
    final c = copyController(r, host);
    await c.load();
    await c.review('/copies');
    await c.prepare(c.draft!);
    r.acknowledgementGate = Completer();
    final pending = c.acknowledge(c.history!, inspectedAndStopped: true);
    await waitUntil(() => c.busy);
    expect(c.canStop, false);
    final cancels = host.cancels;
    await c.stop();
    expect(host.cancels, cancels);
    expect(c.busy, true);
    r.acknowledgementGate!.complete();
    await pending;
    expect(c.history!.needsRecovery, false);
    c.dispose();
  });
  test('cleanup uncertainty retains shared ownership and blocks a replacement controller', () async {
    final r = await copyRecords(), host = CopyHost();
    host.fail = true;
    host.clean = false;
    host.failCleanup = true;
    final c = copyController(r, host);
    await c.load();
    await c.review('/copies');
    await c.prepare(c.draft!);
    expect(c.cleanupUncertain, true);
    expect(c.canAcknowledge, false);
    final replacement = copyController(r, CopyHost());
    await replacement.load();
    expect(replacement.canReview, false);
    expect(replacement.canAcknowledge, false);
    replacement.dispose();
    c.dispose();
  });
}
