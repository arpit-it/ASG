// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'model_catalog.dart';
import 'runtime_capabilities.dart';
import 'runtime_setup.dart';

enum CheckpointMemoryState {
  unknown,
  unavailable,
  exceedsTotal,
  pressure,
  estimated,
}

/// Advisory snapshot for a new load; never proof of an actual peak or readiness.
class CheckpointMemory {
  const CheckpointMemory(this.state, this.detail, {this.workingBytes});
  final CheckpointMemoryState state;
  final String detail;
  final int? workingBytes;
  static const reserveBytes = 6 * gib;

  static CheckpointMemory assess({
    required RuntimeCapabilities? capabilities,
    required RuntimeBackend backend,
    required ModelCandidate? model,
    required ModelHardware? memory,
  }) {
    if (capabilities == null) {
      return const CheckpointMemory(
        CheckpointMemoryState.unknown,
        'Inspect capabilities for this selection before estimating memory.',
      );
    }
    final chosen = backend == RuntimeBackend.auto
        ? capabilities.preferred
        : capabilities.backends.firstWhere((item) => item.backend == backend);
    if (!chosen.hostSupported ||
        chosen.missingDependencies.isNotEmpty ||
        chosen.deviceReady == false) {
      return const CheckpointMemory(
        CheckpointMemoryState.unavailable,
        'Selected backend unavailable. Resolve its host, dependency or device findings before estimating memory.',
      );
    }
    if (model?.supported != true || model?.quantized == null) {
      return const CheckpointMemory(
        CheckpointMemoryState.unknown,
        'Scan and select a complete checkpoint before estimating memory.',
      );
    }
    if (chosen.backend == RuntimeBackend.torch && model!.quantized!) {
      return const CheckpointMemory(
        CheckpointMemoryState.unavailable,
        'Incompatible checkpoint: Torch/MPS requires unquantized weights. Select compatible weights or explicitly choose MLX.',
      );
    }
    if (chosen.deviceReady != true ||
        memory?.appleSilicon != true ||
        capabilities.host != 'macOS / ARM64') {
      return const CheckpointMemory(
        CheckpointMemoryState.unknown,
        'Estimate requires an inspected available Apple unified-memory device. Inspect again; host RAM is not discrete GPU memory.',
      );
    }
    final weights = model?.weightBytes;
    final total = memory?.memoryBytes;
    final available = memory?.availableBytes;
    // Keep arithmetic exact on native and JavaScript, and reject invalid probes.
    const largest = 1125899906842624;
    if (weights == null ||
        weights <= 0 ||
        weights > largest ||
        total == null ||
        total <= 0 ||
        total > largest ||
        (available != null && (available < 0 || available > total))) {
      return const CheckpointMemory(
        CheckpointMemoryState.unknown,
        'Measured weights or consistent host RAM unavailable. Rescan files and inspect again.',
      );
    }
    // Same conservative heuristic as the catalog, not architecture/context math.
    final working = (weights * 5 + 3) ~/ 4 + 4 * gib;
    if (working + reserveBytes > total) {
      return CheckpointMemory(
        CheckpointMemoryState.exceedsTotal,
        'Exceeds estimated total RAM budget. Select smaller compatible weights or a host with more memory.',
        workingBytes: working,
      );
    }
    if (available == null) {
      return CheckpointMemory(
        CheckpointMemoryState.unknown,
        'Estimated total RAM budget fits; current free/reclaimable RAM is unknown. Inspect again before loading.',
        workingBytes: working,
      );
    }
    if (available < working) {
      return CheckpointMemory(
        CheckpointMemoryState.pressure,
        'Current memory pressure: estimated working memory exceeds free/reclaimable RAM. Close other models/apps and inspect again.',
        workingBytes: working,
      );
    }
    return CheckpointMemory(
      CheckpointMemoryState.estimated,
      'Within estimated RAM budget for a new bounded-context load; actual peak, model loading and inference remain unverified.',
      workingBytes: working,
    );
  }
}
