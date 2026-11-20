// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'project_inspection.dart';
import 'requirements_board.dart';

/// Captured app-owned data for advisory review, never sharing or tool authority.
/// Concrete captures retain their separate versioned payloads and identities.
abstract interface class ImportedRepositoryContext {
  String get recordJson;
  String get digest;
  bool get sourceVerified;
  bool get includesSource;
  List<({String path, int byteLength, String digest, String text})>
  get capturedFiles;
  bool matchesPlanningInputs(
    ProjectInspection inspection,
    RequirementsBoard requirements,
  );
}
