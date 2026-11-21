// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:asg/controllers/imported_dart_diagnostics_controller.dart';
import 'package:asg/models/imported_commit_edit_comparison.dart';
import 'package:asg/models/imported_dart_diagnostics.dart';
import 'package:asg/services/imported_dart_diagnostics_host.dart';
import 'package:asg/services/imported_dart_diagnostics_store.dart';
import 'package:asg/services/imported_commit_copy_store.dart';
import 'package:asg/services/imported_commit_edit_store.dart';
import 'package:asg/services/imported_commit_edit_comparison_store.dart';
import 'package:asg/services/inspected_folder_store.dart';

import 'imported_commit_copy_controller_test.dart' show CopyRecords, waitUntil;
import 'imported_commit_edit_comparison_controller_test.dart'
    show comparisonRecords, comparisonResult;

ImportedDartSdkIdentity diagnosticSdk([String root = '/trusted/sdk']) =>
    ImportedDartSdkIdentity.create(
      root: root,
      version: '3.13.5',
      runtimeHash: 'a' * 64,
      analyzerHash: 'b' * 64,
      libraryHash: 'c' * 64,
      libraryFiles: 1,
      libraryBytes: 100,
    );
ImportedDartDiagnosticsObservation diagnosticResult(
  ImportedDartDiagnosticsRequest r, {
  String status = 'clean',
}) => ImportedDartDiagnosticsObservation.fromJson(
  jsonEncode({
    'version': 1,
    'scope': 'imported-dart-diagnostics',
    'request_sha256': r.digest,
    'run_id': r.runId,
    'comparison_request_sha256': r.comparison.digest,
    'sdk_identity_sha256': r.sdk.digest,
    'selected_path': r.selectedPath,
    'source_sha256': sha256.convert(utf8.encode(r.replacement)).toString(),
    'status': status,
    'reason': status == 'clean' ? null : 'unavailable',
    'protocol_version': status == 'clean' ? '1.40.1' : null,
    'diagnostics': [],
    'source_verified': false,
    'project_verified': false,
    'mutation_authorized': false,
    'execution_authorized': false,
    'recorded_at': DateTime.utc(2026).toIso8601String(),
  }),
  request: r,
);

class DiagnosticHost implements ImportedDartDiagnosticsHost {
  int reviews = 0, calls = 0;
  bool clean = true, fail = false, failCleanup = false, available = true;
  Completer<ImportedDartSdkIdentity>? reviewGate;
  Completer<ImportedDartDiagnosticsObservation>? gate;
  void Function()? onReview, onRead;
  @override
  bool get supported => available;
  @override
  bool get cleanupConfirmed => clean;
  @override
  ImportedDartDiagnosticsObservation? get lastObservation => null;
  @override
  Future<ImportedDartSdkIdentity> reviewSdk({
    required ImportedCommitEditComparisonRequest comparison,
    required String sdkRoot,
  }) async {
    reviews++;
    onReview?.call();
    return reviewGate == null
        ? diagnosticSdk(sdkRoot)
        : await reviewGate!.future;
  }

  @override
  Future<ImportedDartDiagnosticsObservation> diagnose(
    ImportedDartDiagnosticsRequest r,
  ) async {
    calls++;
    onRead?.call();
    if (fail) throw StateError('private');
    return gate == null ? diagnosticResult(r) : await gate!.future;
  }

  @override
  Future<void> cancel() async {
    if (failCleanup) throw StateError('unknown cleanup');
    clean = true;
    if (gate != null && !gate!.isCompleted) {
      gate!.completeError(StateError('stopped'));
    }
    if (reviewGate != null && !reviewGate!.isCompleted) {
      reviewGate!.completeError(StateError('stopped'));
    }
  }

  @override
  Future<void> dispose() => cancel();
}

ImportedDartDiagnosticsController diagnosticController(
  CopyRecords r,
  DiagnosticHost h, {
  String status = 'matching',
}) {
  final compared = ImportedCommitEditComparisonStore(r)
      .read('/project', 'd' * 32)
      .request;
  return ImportedDartDiagnosticsController(
    comparison: compared,
    observation: comparisonResult(compared, status: status),
    store: ImportedDartDiagnosticsStore(r),
    host: h,
    runId: () => 'e' * 32,
  );
}

void main() {
  test('loading never launches; SDK review and exact consent produce one bounded observation with zero writes', () async {
    final r = await comparisonRecords(),
        h = DiagnosticHost(),
        c = diagnosticController(await comparisonRecords(), DiagnosticHost());
    c.dispose();
    final live = diagnosticController(r, h);
    await live.load();
    expect(h.reviews, 0);
    expect(h.calls, 0);
    expect(live.canReview, true);
    expect(live.canDiagnose, false);
    await live.reviewSdk('/trusted/sdk');
    final reviewed = live.request!;
    expect(h.reviews, 1);
    expect(live.canDiagnose, true);
    await live.diagnose(
      ImportedDartDiagnosticsRequest.restore(reviewed.requestJson),
    );
    expect(h.calls, 0);
    await live.diagnose(reviewed);
    expect(h.calls, 1);
    expect(live.resultCurrent, true);
    expect(live.lastObserved, live.result);
    expect(live.request, isNull);
    expect(live.canDiagnose, false);
    expect(r.updatesSeen.every((m) => m.isEmpty), true);
    live.dispose();
  });
  test('changed or refused comparisons and all four durable changes block dispatch', () async {
    for (final status in ['changed', 'refused']) {
      final r = await comparisonRecords(), h = DiagnosticHost();
      final c = diagnosticController(r, h, status: status);
      await c.load();
      expect(c.canReview, false);
      expect(h.calls, 0);
      c.dispose();
    }
    for (final key in [
      ImportedCommitCopyStore.key('/project'),
      ImportedCommitEditStore.key('/project'),
      ImportedCommitEditComparisonStore.runtimeKey,
      InspectedFolderStore.key,
    ]) {
      final r = await comparisonRecords(), h = DiagnosticHost();
      final c = diagnosticController(r, h);
      await c.load();
      r.values[key] = 'changed';
      await c.reviewSdk('/trusted/sdk');
      expect(h.reviews, 0);
      expect(c.stale, true);
      expect(r.updatesSeen.every((m) => m.isEmpty), true);
      c.dispose();
    }
  });
  test(
    'SDK review completion and diagnostics completion recheck durable inputs',
    () async {
      for (final duringReview in [true, false]) {
        final r = await comparisonRecords(), h = DiagnosticHost();
        final c = diagnosticController(r, h);
        await c.load();
        if (duringReview) {
          h.onReview = () => r.values[InspectedFolderStore.key] = 'changed';
          await c.reviewSdk('/trusted/sdk');
          expect(c.request, isNull);
          expect(h.calls, 0);
        } else {
          await c.reviewSdk('/trusted/sdk');
          h.onRead = () =>
              r.values[ImportedCommitEditComparisonStore.runtimeKey] =
                  'changed';
          await c.diagnose(c.request!);
          expect(c.resultCurrent, false);
          expect(c.result, isNull);
        }
        expect(r.updatesSeen.every((m) => m.isEmpty), true);
        c.dispose();
      }
    },
  );
  test(
    'review worker shares source lease and Stop prevents late reviewed intent',
    () async {
      final r = await comparisonRecords(),
          h = DiagnosticHost()..reviewGate = Completer();
      final c = diagnosticController(r, h);
      await c.load();
      final pending = c.reviewSdk('/trusted/sdk');
      await waitUntil(() => h.reviews == 1);
      expect(ImportedDartDiagnosticsStore(r).readBusy, true);
      final other = diagnosticController(r, DiagnosticHost());
      await other.load();
      expect(other.canReview, false);
      await c.stop();
      await pending;
      expect(c.request, isNull);
      expect(c.resultCurrent, false);
      expect(ImportedDartDiagnosticsStore(r).readBusy, false);
      c.dispose();
      other.dispose();
    },
  );
  test(
    'dispose cancels in-flight diagnostics and cannot promote late result',
    () async {
      final r = await comparisonRecords(),
          h = DiagnosticHost()..gate = Completer();
      final c = diagnosticController(r, h);
      await c.load();
      await c.reviewSdk('/trusted/sdk');
      final p = c.diagnose(c.request!);
      await waitUntil(() => h.calls == 1);
      c.dispose();
      await p;
      await Future<void>.delayed(Duration.zero);
      expect(c.result, isNull);
      expect(ImportedDartDiagnosticsStore(r).readBusy, false);
    },
  );
  test('failed retry preserves previous observation as historical and unknown cleanup holds lease', () async {
    final r = await comparisonRecords(), h = DiagnosticHost();
    final c = diagnosticController(r, h);
    await c.load();
    await c.reviewSdk('/trusted/sdk');
    await c.diagnose(c.request!);
    final previous = c.lastObserved;
    await c.reviewSdk('/trusted/sdk');
    h.fail = true;
    h.onRead = () => h.clean = false;
    h.failCleanup = true;
    await c.diagnose(c.request!);
    expect(c.lastObserved, same(previous));
    expect(c.resultCurrent, false);
    expect(c.cleanupUncertain, true);
    expect(ImportedDartDiagnosticsStore(r).readBusy, true);
    expect(c.canReview, false);
    h.failCleanup = false;
    h.clean = true;
    c.dispose();
    await Future<void>.delayed(Duration.zero);
    expect(ImportedDartDiagnosticsStore(r).readBusy, false);
  });
}
