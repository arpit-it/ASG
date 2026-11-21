// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_workfile_comparison.dart';
import 'imported_workfile_host.dart';

ImportedWorkfileHost createImportedWorkfileHost() =>
    UnsupportedImportedWorkfileHost();

class UnsupportedImportedWorkfileHost implements ImportedWorkfileHost {
  @override
  bool get supported => false;
  @override
  bool get cleanupConfirmed => true;
  @override
  ImportedWorkfileObservation? get lastObservation => null;
  @override
  Future<ImportedWorkfileObservation> inspect(
    ImportedWorkfileRequest request,
  ) async => throw StateError(
    'Selected working-file comparison is unavailable on this platform.',
  );
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
