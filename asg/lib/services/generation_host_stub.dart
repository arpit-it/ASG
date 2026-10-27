// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/app_definition.dart';
import '../models/project.dart';
import '../models/source_generation.dart';
import 'generation_host.dart';

GenerationHost createGenerationHost() => UnsupportedGenerationHost();

class UnsupportedGenerationHost implements GenerationHost {
  @override
  bool get supported => false;
  Never unavailable() => throw UnsupportedError(
    'Source generation currently requires the macOS app and an installed Flutter SDK.',
  );
  @override
  Future<GeneratedProject> generate({
    required StudioProject project,
    required AppDefinition definition,
    required String parent,
    required String name,
    required String sdk,
    required String python,
    void Function()? authorizeWrite,
  }) async => unavailable();
  @override
  Future<GeneratedProject> verify(
    GeneratedProject project,
    GenerationProgress progress, {
    bool resume = false,
  }) async => unavailable();
  @override
  void cancelVerification() {}
  @override
  Future<Uri> startPreview(GeneratedProject project) async => unavailable();
  @override
  Future<void> openPreview(Uri uri) async => unavailable();
  @override
  Future<void> stopPreview() async {}
  @override
  Future<void> dispose() async {}
}
