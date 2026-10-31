// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

const gib = 1024 * 1024 * 1024;

class ModelCatalogEntry {
  const ModelCatalogEntry({
    required this.repository,
    required this.name,
    required this.description,
    required this.github,
  });
  final String repository, name, description, github;
}

class ModelCatalogMetadata {
  const ModelCatalogMetadata({
    required this.revision,
    required this.license,
    required this.architecture,
    required this.bits,
    required this.mlxFormat,
    required this.weightBytes,
    required this.downloadBytes,
    required this.checkedAt,
  });
  final String revision, license, architecture;
  final int bits, weightBytes, downloadBytes;
  final bool mlxFormat;
  final DateTime checkedAt;
  bool get runtimeCompatible =>
      architecture == 'Qwen3_5ForConditionalGeneration' &&
      bits == 4 &&
      mlxFormat;
}

class ModelHardware {
  const ModelHardware({
    required this.appleSilicon,
    this.memoryBytes,
    this.availableBytes,
    this.detail = 'Hardware detection unavailable.',
  });
  final bool appleSilicon;
  final int? memoryBytes, availableBytes;
  final String detail;
}

enum ModelFit {
  unknown,
  exceedsMemory,
  runtimeUnsupported,
  estimatedFit,
  memoryPressure,
  alreadyLoaded,
}

class ModelAssessment {
  const ModelAssessment(
    this.fit,
    this.detail, {
    this.estimatedBytes,
    this.fitsMemory,
  });
  final ModelFit fit;
  final String detail;
  final int? estimatedBytes;
  final bool? fitsMemory;
  bool get canChoose =>
      fit == ModelFit.estimatedFit ||
      fit == ModelFit.memoryPressure ||
      fit == ModelFit.alreadyLoaded;

  static ModelAssessment assess(
    ModelHardware host,
    ModelCatalogMetadata? model,
  ) {
    if (model == null) {
      return const ModelAssessment(
        ModelFit.unknown,
        'Check source metadata before choosing. No weights have been downloaded.',
      );
    }
    // Count every resident MoE weight. Keep 6 GiB for OS/apps, plus a
    // bounded-context runtime/cache allowance. Estimates are not benchmarks.
    final working = (model.weightBytes * 1.25).ceil() + 4 * gib;
    final total = host.memoryBytes;
    final fits = host.appleSilicon && total != null
        ? working + 6 * gib <= total
        : null;
    if (!host.appleSilicon || !model.runtimeCompatible) {
      return ModelAssessment(
        ModelFit.runtimeUnsupported,
        'Not enabled in the current ASG runtime. Hardware fit alone does not establish compatibility.',
        estimatedBytes: host.appleSilicon ? working : null,
        fitsMemory: fits,
      );
    }
    if (total == null) {
      return const ModelAssessment(
        ModelFit.unknown,
        'Host memory is unknown; fit cannot be estimated.',
      );
    }
    if (working + 6 * gib > total) {
      return ModelAssessment(
        ModelFit.exceedsMemory,
        'Exceeds conservative memory budget including 6 GiB for OS/apps.',
        estimatedBytes: working,
        fitsMemory: fits,
      );
    }
    if (host.availableBytes == null || host.availableBytes! < working) {
      return ModelAssessment(
        ModelFit.memoryPressure,
        'Estimated total-memory fit; current free/reclaimable memory is insufficient or unknown. Close other models/apps before loading.',
        estimatedBytes: working,
        fitsMemory: fits,
      );
    }
    return ModelAssessment(
      ModelFit.estimatedFit,
      'Estimated fit for bounded context. Load, coding quality, speed, structured edits and cancellation are unverified.',
      estimatedBytes: working,
      fitsMemory: fits,
    );
  }
}

/// Exact pinned source matched to a fresh idle local MLX runtime observation.
/// This identifies an existing load; it never supplies memory credit to another.
class ResidentCatalogModel {
  const ResidentCatalogModel(this.repository, this.revision);
  final String repository, revision;
}

class ModelCatalogChoice {
  const ModelCatalogChoice(this.entry, this.metadata);
  final ModelCatalogEntry entry;
  final ModelCatalogMetadata metadata;
}

String memorySize(int bytes) => '${(bytes / gib).toStringAsFixed(1)} GiB';
