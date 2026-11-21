// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_index_observation.dart';

abstract interface class ImportedIndexHost {
  bool get supported;
  bool get cleanupConfirmed;
  ImportedIndexObservation? get lastObservation;
  Future<ImportedIndexObservation> inspect(ImportedIndexReadRequest request);
  Future<void> cancel();
  Future<void> dispose();
}
