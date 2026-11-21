// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import '../models/imported_workfile_comparison.dart';

abstract interface class ImportedWorkfileHost {
  bool get supported;
  bool get cleanupConfirmed;
  ImportedWorkfileObservation? get lastObservation;
  Future<ImportedWorkfileObservation> inspect(ImportedWorkfileRequest request);
  Future<void> cancel();
  Future<void> dispose();
}
