// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/app_definition.dart';
import '../models/generation_capabilities.dart';
import '../models/project.dart';
import '../models/source_generation.dart';

typedef GenerationProgress = Future<void> Function(GeneratedProject project);

abstract interface class GenerationHost {
  bool get supported;
  Future<GeneratedProject> generate({
    required StudioProject project,
    required AppDefinition definition,
    required String parent,
    required String name,
    required String sdk,
    required String python,
    // Synchronous guard immediately before each filesystem mutation.
    // An already dispatched filesystem operation may finish.
    void Function()? authorizeWrite,
  });

  /// Resume preserves a confirmed successful prefix and refuses uncertain
  /// dispatches. The default explicit retry restarts the complete fixed graph.
  Future<GeneratedProject> verify(
    GeneratedProject project,
    GenerationProgress progress, {
    bool resume = false,
  });

  /// Requests termination of verification; completion is reported via progress.
  void cancelVerification();
  Future<Uri> startPreview(GeneratedProject project);
  Future<void> openPreview(Uri uri);
  Future<void> stopPreview();
  Future<void> dispose();
}

/// Optional reporting contract; unknown integrations do not inherit capabilities.
abstract interface class GenerationCapabilitySource {
  GenerationCapabilities get capabilities;
}
