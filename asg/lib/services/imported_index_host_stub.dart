// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_index_observation.dart';
import 'imported_index_host.dart';

ImportedIndexHost createImportedIndexHost() => UnsupportedImportedIndexHost();

class UnsupportedImportedIndexHost implements ImportedIndexHost {
  @override
  bool get supported => false;
  @override
  bool get cleanupConfirmed => true;
  @override
  ImportedIndexObservation? get lastObservation => null;
  @override
  Future<ImportedIndexObservation> inspect(
    ImportedIndexReadRequest request,
  ) async => throw StateError(
    'Local index observation is unavailable on this platform.',
  );
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
