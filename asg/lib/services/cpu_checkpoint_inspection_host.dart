// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/cpu_checkpoint_inspection.dart';

/// Optional experimental preparation boundary; does not enable a managed backend.
abstract interface class CpuCheckpointInspectionHost {
  Future<CpuCheckpointInspection> inspectCpuCheckpoint(
    String python,
    String modelPath, {
    required bool experimentalCpu,
    int? maxWeightBytes,
  });
}
