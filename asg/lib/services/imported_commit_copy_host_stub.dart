// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_copy_request.dart';
import '../models/imported_commit_copy_observation.dart';
import 'imported_commit_copy_host.dart';

ImportedCommitCopyHost createImportedCommitCopyHost() =>
    UnsupportedImportedCommitCopyHost();

class UnsupportedImportedCommitCopyHost implements ImportedCommitCopyHost {
  @override
  bool get supported => false;
  @override
  bool get cleanupConfirmed => true;
  @override
  ImportedCommitCopyObservation? get lastObservation => null;
  @override
  Future<ImportedCommitCopyObservation> prepare(
    ImportedCommitCopyRequest request,
  ) async => throw StateError(
    'Immutable baseline copy is unavailable on this platform.',
  );
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
