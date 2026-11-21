// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/imported_commit_edit_controller.dart';
import 'package:asg/models/imported_commit_edit_request.dart';
import 'package:asg/models/imported_commit_edit_observation.dart';
import 'package:asg/models/imported_commit_edit_record.dart';
import 'package:asg/models/imported_commit_copy_request.dart';
import 'package:asg/models/imported_commit_copy_record.dart';
import 'package:asg/models/imported_commit_proposal_record.dart';
import 'package:asg/services/imported_commit_edit_host.dart';
import 'package:asg/services/imported_commit_edit_store.dart';
import 'package:asg/services/imported_commit_copy_store.dart';
import 'package:asg/services/imported_commit_proposal_store.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/models/runtime_setup.dart';

import 'imported_commit_copy_controller_test.dart' as copy;
import 'imported_commit_copy_record_test.dart' show copyResult;
import 'imported_commit_copy_recheck_controller_test.dart' show RecheckHost;
import 'imported_commit_edit_observation_test.dart' show editResult;
import 'imported_plan_test.dart' show finding;

class EditRecords extends copy.CopyRecords {
  Completer<void>? editAdmissionGate,
      editCompletionGate,
      editAcknowledgementGate;
  bool failCompletion = false, loseAdmission = false, loseCompletion = false;
  void Function(ImportedCommitEditRecord)? afterEditWrite;
  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    void Function()? authorize,
  }) async {
    final raw = updates[ImportedCommitEditStore.key('/project')],
        record = raw == null ? null : ImportedCommitEditRecord.decode(raw);
    if (record?.latest?.phase == ImportedCommitEditPhase.pending) {
      await editAdmissionGate?.future;
    }
    if (record?.latest?.phase == ImportedCommitEditPhase.prepared) {
      await editCompletionGate?.future;
      if (failCompletion) {
        throw StateError('synthetic final persistence failure');
      }
    }
    if (record?.latest?.acknowledgedAt != null) {
      await editAcknowledgementGate?.future;
    }
    await super.commitRecords(
      expected: expected,
      updates: updates,
      authorize: authorize,
    );
    if (record != null) afterEditWrite?.call(record);
    if (record?.latest?.phase == ImportedCommitEditPhase.pending &&
        loseAdmission) {
      throw StateError('lost admission confirmation');
    }
    if (record?.latest?.phase == ImportedCommitEditPhase.prepared &&
        loseCompletion) {
      throw StateError('lost completion confirmation');
    }
  }
}

Future<EditRecords> editRecords() async {
  final old = await copy.copyRecords(), r = EditRecords();
  r.values.addAll(old.values);
  final saved = ImportedCommitProposalRecord.decode(
    r.values[ImportedCommitProposalStore.key('/project')]!,
  );
  final req = ImportedCommitCopyRequest.create(
    saved: saved,
    python: '/trusted/python',
    destination: '/copies',
    attemptId: 'a' * 32,
  );
  final history = ImportedCommitCopyRecord.empty('/project')
      .begin(req, DateTime.utc(2026))
      .settle(req, copyResult(req), DateTime.utc(2026));
  r.values[ImportedCommitCopyStore.key('/project')] = history.recordJson;
  r.updatesSeen.clear();
  return r;
}

class EditHost implements ImportedCommitEditHost {
  int calls = 0, cancels = 0;
  bool clean = true, fail = false, failCleanup = false, supportedValue = true;
  Completer<ImportedCommitEditObservation>? gate;
  void Function(ImportedCommitEditRequest)? onPrepare;
  ImportedCommitEditObservation? last;
  @override
  bool get supported => supportedValue;
  @override
  bool get cleanupConfirmed => clean;
  @override
  ImportedCommitEditObservation? get lastObservation => last;
  @override
  Future<ImportedCommitEditObservation> prepare(
    ImportedCommitEditRequest request,
  ) async {
    calls++;
    onPrepare?.call(request);
    if (fail) throw StateError('private');
    return last = gate == null ? editResult(request) : await gate!.future;
  }

  @override
  Future<void> cancel() async {
    cancels++;
    if (failCleanup) throw StateError('private cleanup');
    clean = true;
    if (gate != null && !gate!.isCompleted) {
      gate!.completeError(StateError('stopped'));
    }
  }

  @override
  Future<void> dispose() => cancel();
}

ImportedCommitEditController editController(
  EditRecords r,
  EditHost host,
  RecheckHost reader, {
  String? expectedCopyDigest,
}) {
  var id = 0;
  return ImportedCommitEditController(
    root: '/project',
    inspection: finding(),
    store: ImportedCommitEditStore(r),
    host: host,
    reader: reader,
    expectedCopyDigest: expectedCopyDigest,
    clock: () => DateTime.utc(2026),
    attemptId: () => (++id).toRadixString(16).padLeft(32, '0'),
  );
}

Future<void> reviewEdit(ImportedCommitEditController c) async {
  await c.load();
  await c.review('/output');
  expect(c.draft, isNotNull, reason: c.error);
}

void main() {
  test(
    'fresh review reads only; durable pending and full fence precede writing',
    () async {
      final r = await editRecords(), h = EditHost(), reader = RecheckHost();
      final original = r.values[ImportedCommitCopyStore.key('/project')];
      final c = editController(r, h, reader);
      await reviewEdit(c);
      expect(reader.calls, 1);
      expect(h.calls, 0);
      expect(r.values[ImportedCommitEditStore.key('/project')], isNull);
      h.onPrepare = (req) {
        final pending = ImportedCommitEditRecord.decode(
          r.values[ImportedCommitEditStore.key('/project')]!,
        );
        expect(pending.latest!.phase, ImportedCommitEditPhase.pending);
        expect(pending.latest!.request.digest, req.digest);
      };
      await c.prepare(c.draft!);
      expect(h.calls, 1);
      expect(c.history!.lastPrepared, isNotNull);
      expect(r.values[ImportedCommitCopyStore.key('/project')], original);
      c.dispose();
    },
  );
  test(
    'clicked copy history and stale current runtime prevent review or dispatch',
    () async {
      final r = await editRecords(), h = EditHost(), reader = RecheckHost();
      final wrong = editController(r, h, reader, expectedCopyDigest: 'f' * 64);
      await wrong.load();
      expect(wrong.canReview, false);
      wrong.dispose();
      final c = editController(r, EditHost(), RecheckHost());
      await reviewEdit(c);
      await RuntimeSetupStore(r)
          .save(const RuntimeSetup(python: '/changed/python'));
      await c.prepare(c.draft!);
      expect(c.host.lastObservation, isNull);
      expect(r.values[ImportedCommitEditStore.key('/project')], isNull);
      c.dispose();
    },
  );
  test(
    'changed or stopped fresh read cannot create an actionable draft',
    () async {
      final r = await editRecords(),
          h = EditHost(),
          reader = RecheckHost()..status = 'changed';
      final c = editController(r, h, reader);
      await c.load();
      await c.review('/output');
      expect(c.draft, isNull);
      reader.status = 'matching';
      reader.gate = Completer();
      final pending = c.review('/output');
      await copy.waitUntil(() => reader.calls == 2);
      await c.stop();
      await pending;
      expect(c.draft, isNull);
      expect(h.calls, 0);
      expect(r.values[ImportedCommitEditStore.key('/project')], isNull);
      c.dispose();
    },
  );
  test('lost pending confirmation never dispatches and survives as unresolved history', () async {
    final r = await editRecords(),
        h = EditHost(),
        c = editController(r, h, RecheckHost());
    await reviewEdit(c);
    r.loseAdmission = true;
    await c.prepare(c.draft!);
    expect(h.calls, 0);
    expect(
      ImportedCommitEditRecord.decode(
        r.values[ImportedCommitEditStore.key('/project')]!,
      ).needsRecovery,
      true,
    );
    expect(c.reported, isNull);
    c.dispose();
  });
  test('changed inputs after admission refuse host entry and retain unresolved pending journal', () async {
    final r = await editRecords(), h = EditHost();
    final c = editController(r, h, RecheckHost());
    await reviewEdit(c);
    r.afterEditWrite = (record) {
      if (record.latest!.phase == ImportedCommitEditPhase.pending) {
        r.values[ImportedCommitProposalStore.key('/project')] = 'changed';
      }
    };
    await c.prepare(c.draft!);
    expect(h.calls, 0);
    expect(
      ImportedCommitEditRecord.decode(
        r.values[ImportedCommitEditStore.key('/project')]!,
      ).needsRecovery,
      true,
    );
    expect(c.history!.lastPrepared, isNull);
    c.dispose();
  });
  test('Stop retains late receipt only as recovery evidence and preserves old success', () async {
    final r = await editRecords(), h = EditHost();
    final c = editController(r, h, RecheckHost());
    await reviewEdit(c);
    await c.prepare(c.draft!);
    final good = c.history!.lastPrepared;
    await c.load();
    await c.review('/output');
    h.gate = Completer();
    final pending = c.prepare(c.draft!);
    await copy.waitUntil(() => h.calls == 2);
    await c.stop();
    await pending;
    expect(c.history!.lastPrepared!.request.digest, good!.request.digest);
    expect(c.history!.latest!.phase, ImportedCommitEditPhase.unconfirmed);
    expect(c.canPrepare, false);
    c.dispose();
  });
  test('lost final confirmation requires explicit reload and never overwrites the winner', () async {
    final r = await editRecords(), h = EditHost();
    final c = editController(r, h, RecheckHost());
    await reviewEdit(c);
    r.loseCompletion = true;
    await c.prepare(c.draft!);
    expect(c.history!.lastPrepared, isNull);
    expect(
      ImportedCommitEditRecord.decode(
        r.values[ImportedCommitEditStore.key('/project')]!,
      ).lastPrepared,
      isNotNull,
    );
    await c.load();
    expect(c.history!.lastPrepared, isNotNull);
    expect(h.calls, 1);
    c.dispose();
  });
  test('disposed host result cannot publish and cleanup uncertainty prevents replacement overlap', () async {
    final r = await editRecords(), h = EditHost();
    final c = editController(r, h, RecheckHost());
    await reviewEdit(c);
    h.gate = Completer();
    final pending = c.prepare(c.draft!);
    await copy.waitUntil(() => h.calls == 1);
    c.dispose();
    await pending;
    expect(c.history!.lastPrepared, isNull);
    expect(
      ImportedCommitEditRecord.decode(
        r.values[ImportedCommitEditStore.key('/project')]!,
      ).needsRecovery,
      true,
    );
    final unknown = EditHost()
      ..fail = true
      ..failCleanup = true;
    final next = editController(await editRecords(), unknown, RecheckHost());
    await reviewEdit(next);
    unknown.onPrepare = (_) => unknown.clean = false;
    await next.prepare(next.draft!);
    expect(next.cleanupUncertain, true);
    expect(next.store.readBusy, true);
    next.dispose();
  });
  test('recovery inspection neither replays nor promotes and acknowledgement has no Stop', () async {
    final r = await editRecords(), h = EditHost()..fail = true;
    final c = editController(r, h, RecheckHost());
    await reviewEdit(c);
    await c.prepare(c.draft!);
    final old = c.history!;
    await c.acknowledge(old, inspectedAndStopped: false);
    expect(c.history!.needsRecovery, true);
    r.editAcknowledgementGate = Completer();
    final ack = c.acknowledge(old, inspectedAndStopped: true);
    await Future<void>.delayed(Duration.zero);
    expect(c.canStop, false);
    r.editAcknowledgementGate!.complete();
    await ack;
    expect(c.history!.needsRecovery, false);
    expect(c.history!.lastPrepared, isNull);
    expect(h.calls, 1);
    c.dispose();
  });
}
