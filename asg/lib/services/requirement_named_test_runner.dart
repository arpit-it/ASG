// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/artifact_inspection.dart';
import '../models/project.dart';
import '../models/requirement_check_report.dart';
import '../models/requirements_board.dart';
import 'generation_host_factory.dart';
import 'named_test_session.dart';
import 'requirement_check_report_store.dart';

/// Binds an explicit execution request to one unchanged saved report.
/// No automatic retries: a refused or interrupted run needs a new user action.
class RequirementNamedTestRunner {
  RequirementNamedTestRunner(
    this.store, {
    NamedTestSession Function()? createSession,
  }) : _createSession = createSession ?? _defaultSession;
  final RequirementCheckReportStore store;
  final NamedTestSession Function() _createSession;
  bool _running = false;

  static NamedTestSession _defaultSession() {
    final host = createGenerationHost();
    if (host is NamedTestSession) return host as NamedTestSession;
    // Unsupported hosts own no resources until invoked.
    throw UnsupportedError(
      'Confined named tests require a supported desktop host.',
    );
  }

  Future<void> run(
    StudioProject project,
    RequirementCheckReport selected,
    String requirementId,
    String checkId, {
    required bool Function() authorized,
  }) async {
    if (_running) throw StateError('A named test is already running.');
    _running = true;
    NamedTestSession? session;
    try {
      void checkCurrent() {
        if (!authorized() ||
            store.load(project).snapshotFingerprint !=
                selected.snapshotFingerprint ||
            !selected.canRecordManualObservation ||
            selected.savedProject?.confined != true) {
          throw StateError(
            'Reload current approved confined evidence before running a test.',
          );
        }
      }

      checkCurrent();
      final requirement = selected.results
          .where((r) => r.requirement.id == requirementId)
          .firstOrNull;
      final check = requirement?.requirement.checks
          .where((c) => c.id == checkId)
          .firstOrNull;
      if (check?.type != AcceptanceCheckType.automated ||
          check?.target == null) {
        throw StateError('Choose an authored automated Flutter test target.');
      }
      final saved = selected.savedProject!;
      final owned = session = _createSession();
      if (!owned.supported) {
        throw UnsupportedError(
          'Confined named tests are unavailable on this host.',
        );
      }
      Future<void> validateFiles() async {
        checkCurrent();
        if (await owned.inspectArtifacts(saved) !=
            ArtifactInspection.matching) {
          throw StateError(
            'Saved source or artifacts changed or are unavailable. Verify again.',
          );
        }
        checkCurrent();
      }

      await validateFiles();
      var dispatched = false;
      final result = await owned.runNamedFlutterTest(
        saved,
        check!.target!,
        beforeStart: () async {
          if (dispatched) throw StateError('Repeated test dispatch refused.');
          await validateFiles();
          dispatched = true;
        },
      );
      if (!dispatched) throw StateError('Test dispatch was not authorized.');
      await validateFiles();
      await store.recordNamedTestResult(
        project,
        selected,
        requirementId,
        checkId,
        result,
        DateTime.now().toUtc(),
        authorized: authorized,
      );
    } finally {
      try {
        await session?.dispose();
      } finally {
        _running = false;
      }
    }
  }
}
