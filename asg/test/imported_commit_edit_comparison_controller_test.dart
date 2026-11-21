// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/imported_commit_edit_comparison_controller.dart';
import 'package:asg/models/imported_commit_edit_comparison.dart';
import 'package:asg/services/imported_commit_edit_comparison_host.dart';
import 'package:asg/services/imported_commit_edit_comparison_store.dart';
import 'package:asg/services/imported_commit_copy_store.dart';

import 'imported_commit_proposal_record_test.dart' show historicalRecord;
import 'imported_commit_edit_request_test.dart' show editBasis;
import 'imported_commit_edit_observation_test.dart'
    show sampleEditRequest, editResult;

import 'package:asg/models/imported_commit_edit_record.dart';
import 'package:asg/services/imported_commit_edit_store.dart';

import 'dart:convert';

import 'imported_commit_copy_controller_test.dart'
    show CopyRecords, copyRecords, waitUntil;

ImportedCommitEditComparisonRequest sampleComparisonRequest() =>
    ImportedCommitEditComparisonRequest.create(
      copyHistory: editBasis(historicalRecord()).history,
      editHistory: preparedEdits(),
      python: '/trusted/current-python',
      comparisonId: 'd' * 32,
    );
ImportedCommitEditRecord preparedEdits() {
  final r = sampleEditRequest();
  return ImportedCommitEditRecord.empty(r.root)
      .begin(r, DateTime.utc(2026))
      .settle(r, editResult(r), DateTime.utc(2026));
}

Future<CopyRecords> comparisonRecords() async {
  final r = await copyRecords();
  r.values[ImportedCommitCopyStore.key('/project')] = editBasis(
    historicalRecord(),
  ).history.recordJson;
  r.values[ImportedCommitEditStore.key('/project')] =
      preparedEdits().recordJson;
  r.updatesSeen.clear();
  return r;
}

Map<String, Object?> comparisonData(
  ImportedCommitEditComparisonRequest r, {
  String status = 'matching',
}) => {
  'version': 1,
  'scope': 'imported-commit-edit-comparison',
  'request_sha256': r.digest,
  'comparison_id': r.comparisonId,
  'original_copy': r.originalCopy,
  'proposed_copy': r.proposedCopy,
  'expected_original_fingerprint': r.expectedOriginalFingerprint,
  'expected_proposed_fingerprint': r.expectedProposedFingerprint,
  'status': status,
  'original_fingerprint': status == 'refused'
      ? null
      : r.expectedOriginalFingerprint,
  'proposed_fingerprint': status == 'refused'
      ? null
      : status == 'changed'
      ? 'f' * 64
      : r.expectedProposedFingerprint,
  'original_files': status == 'refused' ? null : r.manifestFiles,
  'proposed_files': status == 'refused' ? null : r.manifestFiles,
  'original_bytes': status == 'refused' ? null : 100,
  'proposed_bytes': status == 'refused' ? null : 100,
  'selected_matches': status == 'refused' ? null : true,
  'comparison': status == 'refused'
      ? null
      : {
          'schemaVersion': 1,
          'commit': r.commit,
          'digest': status == 'changed'
              ? 'f' * 64
              : r.expectedProposedFingerprint,
          'counts': {
            'added': 0,
            'modified': 1,
            'removed': 0,
            'executableChanged': 0,
          },
          'changes': [
            {
              'path': r.selectedPath,
              'kind': 'modified',
              'executableChanged': false,
            },
          ],
          'truncated': false,
        },
  'reason': status == 'refused' ? 'unavailable' : null,
  'source_verified': false,
  'mutation_authorized': false,
  'execution_authorized': false,
  'recorded_at': DateTime.utc(2026).toIso8601String(),
};
ImportedCommitEditComparisonObservation comparisonResult(
  ImportedCommitEditComparisonRequest r, {
  String status = 'matching',
}) => ImportedCommitEditComparisonObservation.fromJson(
  jsonEncode(comparisonData(r, status: status)),
  request: r,
);

class ComparisonHost implements ImportedCommitEditComparisonHost {
  int calls = 0, cancels = 0;
  String status = 'matching';
  bool clean = true, fail = false, failCleanup = false, supportedValue = true;
  Completer<ImportedCommitEditComparisonObservation>? gate;
  void Function(ImportedCommitEditComparisonRequest)? onRead;
  @override
  bool get supported => supportedValue;
  @override
  bool get cleanupConfirmed => clean;
  @override
  ImportedCommitEditComparisonObservation? get lastObservation => null;
  @override
  Future<ImportedCommitEditComparisonObservation> compare(
    ImportedCommitEditComparisonRequest request,
  ) async {
    calls++;
    onRead?.call(request);
    if (fail) throw StateError('private');
    return gate == null
        ? comparisonResult(request, status: status)
        : await gate!.future;
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

ImportedCommitEditComparisonController comparisonController(
  CopyRecords r,
  ComparisonHost host, {
  String? expectedDigest,
}) {
  var id = 0;
  return ImportedCommitEditComparisonController(
    root: '/project',
    store: ImportedCommitEditComparisonStore(r),
    host: host,
    expectedEditHistoryDigest: expectedDigest,
    comparisonId: () => (++id).toRadixString(16).padLeft(32, '0'),
  );
}

void main() {
  test(
    'load and explicit native read use only zero-update durable fences',
    () async {
      final r = await comparisonRecords(),
          h = ComparisonHost(),
          before = Map<String, String>.of(r.values);
      final c = comparisonController(r, h);
      await c.load();
      expect(h.calls, 0);
      expect(c.canCompare, true);
      await c.compare(c.request!);
      expect(h.calls, 1);
      expect(c.result!.status, ImportedCommitEditComparisonStatus.matching);
      expect(c.resultCurrent, true);
      expect(r.values, before);
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      c.dispose();
    },
  );
  test('clicked history and runtime changes prevent dispatch', () async {
    final r = await comparisonRecords(), h = ComparisonHost();
    final wrong = comparisonController(r, h, expectedDigest: 'f' * 64);
    await wrong.load();
    expect(wrong.canCompare, false);
    wrong.dispose();
    final c = comparisonController(r, h);
    await c.load();
    r.values[ImportedCommitEditComparisonStore.runtimeKey] = 'changed';
    await c.compare(c.request!);
    expect(h.calls, 0);
    expect(c.result, isNull);
    c.dispose();
  });
  test(
    'durable admission gate revoked before helper entry has zero dispatch',
    () async {
      final r = await comparisonRecords(),
          h = ComparisonHost(),
          c = comparisonController(r, ComparisonHost());
      await c.load();
      final live = comparisonController(r, h);
      await live.load();
      r.gate = Completer<void>();
      final pending = live.compare(live.request!);
      await Future<void>.delayed(Duration.zero);
      r.values[ImportedCommitCopyStore.key('/project')] = 'changed';
      r.gate!.complete();
      await pending;
      expect(h.calls, 0);
      expect(live.result, isNull);
      live.dispose();
      c.dispose();
    },
  );
  test('changed current inputs after host completion cannot publish', () async {
    final r = await comparisonRecords(), h = ComparisonHost();
    final c = comparisonController(r, h);
    await c.load();
    h.onRead = (_) =>
        r.values[ImportedCommitEditComparisonStore.runtimeKey] = 'changed';
    await c.compare(c.request!);
    expect(h.calls, 1);
    expect(c.result, isNull);
    expect(c.error, isNotNull);
    c.dispose();
  });
  test(
    'Stop retains previous observation as historical and never writes',
    () async {
      final r = await comparisonRecords(), h = ComparisonHost();
      final c = comparisonController(r, h);
      await c.load();
      await c.compare(c.request!);
      final old = c.result;
      await c.load();
      h.gate = Completer();
      final pending = c.compare(c.request!);
      await waitUntil(() => h.calls == 2);
      await c.stop();
      await pending;
      expect(c.result, same(old));
      expect(c.resultCurrent, false);
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      c.dispose();
    },
  );
  test('failed retry never relabels previous result as current', () async {
    final r = await comparisonRecords(), h = ComparisonHost();
    final c = comparisonController(r, h);
    await c.load();
    await c.compare(c.request!);
    final old = c.result;
    await c.load();
    h.fail = true;
    await c.compare(c.request!);
    expect(c.result, same(old));
    expect(c.resultCurrent, false);
    c.dispose();
  });
  test(
    'disposed read cannot publish and retains lease until owned cleanup',
    () async {
      final r = await comparisonRecords(), h = ComparisonHost();
      final c = comparisonController(r, h);
      await c.load();
      await c.load();
      h.gate = Completer();
      final pending = c.compare(c.request!);
      await waitUntil(() => h.calls == 1);
      c.dispose();
      await pending;
      expect(c.result, isNull);
      await Future<void>.delayed(Duration.zero);
      expect(ImportedCommitEditComparisonStore(r).readBusy, false);
    },
  );
  test(
    'uncertain cleanup blocks replacement controller and preserves history',
    () async {
      final r = await comparisonRecords(),
          h = ComparisonHost()
            ..clean = false
            ..fail = true
            ..failCleanup = true;
      final c = comparisonController(r, h);
      await c.load();
      h.clean = true;
      final request = c.request!;
      h.onRead = (_) => h.clean = false;
      await c.compare(request);
      expect(c.cleanupUncertain, true);
      expect(ImportedCommitEditComparisonStore(r).readBusy, true);
      final other = comparisonController(r, ComparisonHost());
      await other.load();
      expect(other.canCompare, false);
      expect(other.workerBlocked, true);
      other.dispose();
      c.dispose();
    },
  );
  test(
    'a refused read retains the previous completed content observation',
    () async {
      final r = await comparisonRecords(), h = ComparisonHost();
      final c = comparisonController(r, h);
      await c.load();
      await c.compare(c.request!);
      final previous = c.result;
      await c.load();
      h.status = 'refused';
      await c.compare(c.request!);
      expect(c.result!.status, ImportedCommitEditComparisonStatus.refused);
      expect(c.lastObserved, same(previous));
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      c.dispose();
    },
  );
}
