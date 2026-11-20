// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/imported_commit_source_observation.dart';
import 'imported_commit_source_host.dart';

ImportedCommitSourceHost createImportedCommitSourceHost() =>
    UnsupportedImportedCommitSourceHost();

class UnsupportedImportedCommitSourceHost implements ImportedCommitSourceHost {
  @override
  bool get supported => false;
  @override
  Future<ImportedCommitSourceObservation> inspect(
    ImportedCommitReadRequest request,
  ) async =>
      throw StateError('Contained source file inspection is unavailable.');
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
