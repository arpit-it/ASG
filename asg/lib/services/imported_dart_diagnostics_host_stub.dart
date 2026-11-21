// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_edit_comparison.dart';
import '../models/imported_dart_diagnostics.dart';
import 'imported_dart_diagnostics_host.dart';

ImportedDartDiagnosticsHost createImportedDartDiagnosticsHost() =>
    UnsupportedImportedDartDiagnosticsHost();

class UnsupportedImportedDartDiagnosticsHost
    implements ImportedDartDiagnosticsHost {
  @override
  bool get supported => false;
  @override
  bool get cleanupConfirmed => true;
  @override
  ImportedDartDiagnosticsObservation? get lastObservation => null;
  @override
  Future<ImportedDartSdkIdentity> reviewSdk({
    required ImportedCommitEditComparisonRequest comparison,
    required String sdkRoot,
  }) async => throw StateError(
    'Isolated Dart diagnostics are unavailable on this platform.',
  );
  @override
  Future<ImportedDartDiagnosticsObservation> diagnose(
    ImportedDartDiagnosticsRequest request,
  ) async => throw StateError(
    'Isolated Dart diagnostics are unavailable on this platform.',
  );
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
