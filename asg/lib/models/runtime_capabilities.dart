// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'runtime_setup.dart';

/// Dependency discovery is not a device probe, model load or memory check.
class RuntimeCapabilities {
  RuntimeCapabilities._(this.host, this.backends);
  final String host;
  final List<BackendCapability> backends;

  factory RuntimeCapabilities.fromJson(Object? value) {
    const invalid = FormatException('Invalid runtime capability report.');
    if (value is! Map<String, dynamic> || value['schema_version'] != 1) {
      throw invalid;
    }
    final host = value['host'];
    final entries = value['backends'];
    if (host is! Map<String, dynamic> ||
        host['system'] is! String ||
        host['machine'] is! String ||
        entries is! List ||
        entries.length != 2) {
      throw invalid;
    }
    // Never render arbitrary child-process strings, even in otherwise valid JSON.
    final system = switch (host['system']) {
      'Darwin' => 'macOS',
      'Linux' => 'Linux',
      'Windows' => 'Windows',
      _ => 'Unknown host',
    };
    final machine = switch (host['machine']) {
      'arm64' || 'aarch64' => 'ARM64',
      'x86_64' || 'AMD64' => 'x64',
      _ => 'unknown architecture',
    };
    final parsed = <BackendCapability>[];
    for (final entry in entries) {
      if (entry is! Map<String, dynamic>) throw invalid;
      final backend = switch ((entry['backend'], entry['device'])) {
        ('mlx', 'metal') => RuntimeBackend.mlx,
        ('torch', 'mps') => RuntimeBackend.torch,
        _ => throw invalid,
      };
      final missing = entry['missing_dependencies'];
      final supported = entry['host_supported'];
      final allowed = backend == RuntimeBackend.mlx
          ? const ['mlx_lm', 'mlx']
          : const ['torch', 'transformers', 'accelerate'];
      if (supported is! bool ||
          missing is! List ||
          missing.any((name) => !allowed.contains(name)) ||
          missing.toSet().length != missing.length ||
          entry['device_ready'] != null ||
          entry['model_compatible'] != null ||
          entry['readiness'] !=
              (supported && missing.isEmpty ? 'unverified' : 'unavailable') ||
          parsed.any((item) => item.backend == backend)) {
        throw invalid;
      }
      parsed.add(
        BackendCapability(
          backend,
          supported,
          List<String>.unmodifiable(missing),
        ),
      );
    }
    return RuntimeCapabilities._(
      '$system / $machine',
      List.unmodifiable(parsed),
    );
  }

  BackendCapability get preferred => backends.firstWhere(
    (entry) =>
        entry.backend ==
        (backends
                .firstWhere((e) => e.backend == RuntimeBackend.mlx)
                .missingDependencies
                .contains('mlx_lm')
            ? RuntimeBackend.torch
            : RuntimeBackend.mlx),
  );
}

class BackendCapability {
  const BackendCapability(
    this.backend,
    this.hostSupported,
    this.missingDependencies,
  );
  final RuntimeBackend backend;
  final bool hostSupported;
  final List<String> missingDependencies;

  String get availability => !hostSupported
      ? 'Unavailable on this host. Choose a compatible local runtime connection.'
      : missingDependencies.isNotEmpty
      ? 'Missing dependencies: ${missingDependencies.join(', ')}. Choose an environment with these packages installed.'
      : 'Dependencies found. Device availability remains unverified until launch.';

  String modelCompatibility(ModelCandidate? model) {
    if (model == null) {
      return 'Model compatibility unknown: scan and select a checkpoint.';
    }
    if (!model.supported || model.quantized == null) {
      return 'Model compatibility unknown: rescan a complete checkpoint.';
    }
    if (backend == RuntimeBackend.torch && model.quantized!) {
      return 'Incompatible metadata: Torch/MPS requires unquantized weights. Select compatible weights or explicitly choose MLX.';
    }
    return 'Model metadata passes the backend format restriction. Actual load, device readiness and memory adequacy remain unverified.';
  }
}
