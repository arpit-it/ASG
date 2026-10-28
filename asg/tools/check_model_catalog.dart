// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
// Explicit live public-metadata smoke. Does not download model weights.
import 'package:asg/services/model_catalog_service.dart';
import 'package:asg/services/model_hardware.dart';
import 'package:asg/models/model_catalog.dart';

import 'dart:io';

Future<void> main() async {
  final hardware = await probeModelHardware();
  stdout.writeln(
    'Host memory: ${hardware.memoryBytes}; available estimate: ${hardware.availableBytes}',
  );
  final service = ModelCatalogService();
  try {
    for (final entry in codingModelCatalog) {
      try {
        final m = await service.check(entry);
        stdout.writeln(
          '${entry.repository} ${m.revision} ${m.downloadBytes} bytes ${m.license} ${m.architecture} ${ModelAssessment.assess(hardware, m).fit.name}',
        );
      } catch (_) {
        stdout.writeln('${entry.repository}: metadata validation failed');
        exitCode = 1;
      }
    }
    final found = await service.search('Coder');
    stdout.writeln('Public search: ${found.length} MLX 4-bit candidates');
  } finally {
    service.close();
  }
}
