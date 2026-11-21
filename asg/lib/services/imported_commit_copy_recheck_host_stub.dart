// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_commit_copy_recheck.dart';
import 'imported_commit_copy_recheck_host.dart';

ImportedCommitCopyRecheckHost createImportedCommitCopyRecheckHost() =>
    UnsupportedImportedCommitCopyRecheckHost();

class UnsupportedImportedCommitCopyRecheckHost
    implements ImportedCommitCopyRecheckHost {
  @override
  bool get supported => false;
  @override
  bool get cleanupConfirmed => true;
  @override
  ImportedCommitCopyRecheckObservation? get lastObservation => null;
  @override
  Future<ImportedCommitCopyRecheckObservation> recheck(
    ImportedCommitCopyRecheckRequest request,
  ) async => throw StateError(
    'Original-copy recheck is unavailable on this platform.',
  );
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
