// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_head_index_observation.dart';
import 'imported_head_index_host.dart';

ImportedHeadIndexHost createImportedHeadIndexHost() =>
    UnsupportedImportedHeadIndexHost();

class UnsupportedImportedHeadIndexHost implements ImportedHeadIndexHost {
  @override
  bool get supported => false;
  @override
  bool get cleanupConfirmed => true;
  @override
  ImportedHeadIndexObservation? get lastObservation => null;
  @override
  Future<ImportedHeadIndexObservation> inspect(
    ImportedHeadIndexRequest request,
  ) async =>
      throw StateError('Declared-object read is unavailable on this platform.');
  @override
  Future<void> cancel() async {}
  @override
  Future<void> dispose() async {}
}
