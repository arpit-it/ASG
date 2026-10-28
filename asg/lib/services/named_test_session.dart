// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/artifact_inspection.dart';
import '../models/named_flutter_test_result.dart';
import '../models/requirements_board.dart';
import '../models/source_generation.dart';

/// One owned, confined named-test session. Inspection grants no authority.
abstract interface class NamedTestSession implements ArtifactInspector {
  bool get supported;
  Future<NamedFlutterTestResult> runNamedFlutterTest(
    GeneratedProject project,
    FlutterTestTarget target, {
    required Future<void> Function() beforeStart,
  });
  Future<void> dispose();
}
