// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// File metadata observations only, never tool execution or readiness evidence.
class GenerationToolchain {
  const GenerationToolchain(this.flutter, this.dart, this.python);
  const GenerationToolchain.unavailable()
    : flutter = 'Not inspected on this host.',
      dart = 'Not inspected on this host.',
      python = 'Not inspected on this host.';
  const GenerationToolchain.failed()
    : flutter = 'Inspection failed or timed out. Check the SDK and retry.',
      dart = 'Inspection failed or timed out. Check the SDK and retry.',
      python = 'Inspection failed or timed out. Check Python and retry.';

  final String flutter, dart, python;
  static const limits =
      'Local file metadata only. No tools were run or installed. Executable bits '
      'do not prove versions, dependencies, permissions, safe contents or a '
      'working build. Generation still requires approval and verification.';
}
