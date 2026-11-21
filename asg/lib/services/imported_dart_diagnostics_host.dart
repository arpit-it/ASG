// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_edit_comparison.dart';
import '../models/imported_dart_diagnostics.dart';

abstract interface class ImportedDartDiagnosticsHost {
  bool get supported;
  bool get cleanupConfirmed;
  ImportedDartDiagnosticsObservation? get lastObservation;
  Future<ImportedDartSdkIdentity> reviewSdk({
    required ImportedCommitEditComparisonRequest comparison,
    required String sdkRoot,
  });
  Future<ImportedDartDiagnosticsObservation> diagnose(
    ImportedDartDiagnosticsRequest request,
  );
  Future<void> cancel();
  Future<void> dispose();
}
