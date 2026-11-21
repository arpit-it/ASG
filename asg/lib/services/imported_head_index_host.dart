// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_head_index_observation.dart';

abstract interface class ImportedHeadIndexHost {
  bool get supported;
  bool get cleanupConfirmed;
  ImportedHeadIndexObservation? get lastObservation;
  Future<ImportedHeadIndexObservation> inspect(
    ImportedHeadIndexRequest request,
  );
  Future<void> cancel();
  Future<void> dispose();
}
