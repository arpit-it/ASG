// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// Structural observations only: never a model readiness or memory-fit verdict.
class CpuCheckpointInspection {
  const CpuCheckpointInspection._(this.weightBytes, this.weightFileCount);
  final int weightBytes, weightFileCount;

  static const scope =
      'Local structure and observed disk bytes only; no dependency, tokenizer, tensor, RAM or inference validation.';

  factory CpuCheckpointInspection.fromJson(Object? value) {
    const invalid = FormatException(
      'Invalid CPU checkpoint inspection report.',
    );
    if (value is! Map<String, dynamic> ||
        value['schema_version'] != 1 ||
        value['backend'] != 'torch' ||
        value['device'] != 'cpu' ||
        value['experimental'] != true ||
        value['readiness'] != 'unverified' ||
        value['checkpoint_structure'] != 'validated' ||
        !value.containsKey('model_compatible') ||
        value['model_compatible'] != null ||
        !value.containsKey('memory_adequate') ||
        value['memory_adequate'] != null ||
        value['inference_verified'] != false) {
      throw invalid;
    }
    final bytes = value['weight_bytes'];
    final count = value['weight_file_count'];
    // Keep observations exact across native and browser integer representations.
    const maximum = 9007199254740991;
    if (bytes is! int ||
        count is! int ||
        bytes < 1 ||
        bytes > maximum ||
        count < 1 ||
        count > bytes) {
      throw invalid;
    }
    // Arbitrary report fields (including scope text) are never retained/rendered.
    return CpuCheckpointInspection._(bytes, count);
  }
}
