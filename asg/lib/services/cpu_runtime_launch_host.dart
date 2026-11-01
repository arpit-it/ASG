// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/runtime_setup.dart';

/// Optional API-only launch for controlled experimental CPU validation.
/// Does not add CPU to supported choices or persist backend selection.
abstract interface class CpuRuntimeLaunchHost {
  /// Starts an owned process, not a readiness or inference confirmation.
  /// The server enforces the load deadline; [maxWeightBytes] is a disk-byte
  /// ceiling, not a RAM quota. Stop and exit use the normal host lifecycle.
  Future<void> startCpuRuntime(
    RuntimeSetup setup,
    String modelId, {
    required bool experimentalCpu,
    int threads = 2,
    int? maxWeightBytes,
    Duration loadTimeout = const Duration(seconds: 180),
  });
}
