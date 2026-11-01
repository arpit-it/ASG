// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Optional API-only check; never enables a supported CPU backend.
abstract interface class CpuEnvironmentPreparationHost {
  /// Checks installed loader APIs without installing packages or loading weights.
  /// Success does not establish checkpoint, memory or inference readiness.
  Future<void> prepareCpuEnvironment(
    String python, {
    required bool experimentalCpu,
  });
}
