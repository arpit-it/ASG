// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_edit_request.dart';
import '../models/imported_commit_edit_observation.dart';
import 'imported_commit_edit_host.dart';

ImportedCommitEditHost createImportedCommitEditHost() =>
    UnsupportedImportedCommitEditHost();

class UnsupportedImportedCommitEditHost implements ImportedCommitEditHost {
  @override
  bool get supported => false;
  @override
  bool get cleanupConfirmed => true;
  @override
  ImportedCommitEditObservation? get lastObservation => null;
  @override
  Future<ImportedCommitEditObservation> prepare(
    ImportedCommitEditRequest request,
  ) async => throw StateError(
    'Isolated proposed copy is unavailable on this platform.',
  );
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
