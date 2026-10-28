// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import '../models/model_catalog.dart';

Future<ModelHardware> probeModelHardware() async {
  if (!Platform.isMacOS) {
    return const ModelHardware(
      appleSilicon: false,
      detail: 'Managed model loading currently requires Apple Silicon macOS.',
    );
  }
  try {
    Future<String> sysctl(String key) async {
      final result = await Process.run('/usr/sbin/sysctl', [
        '-n',
        key,
      ]).timeout(const Duration(seconds: 3));
      if (result.exitCode != 0) throw StateError('Hardware probe failed');
      return (result.stdout as String).trim();
    }

    final arm = await sysctl('hw.optional.arm64') == '1';
    final total = int.tryParse(await sysctl('hw.memsize'));
    int? available;
    try {
      final result = await Process.run(
        '/usr/bin/vm_stat',
        [],
      ).timeout(const Duration(seconds: 3));
      if (result.exitCode == 0) {
        final output = result.stdout as String;
        final page = int.tryParse(
          RegExp(r'page size of (\d+) bytes').firstMatch(output)?.group(1) ??
              '',
        );
        if (page != null) {
          int pages(String key) =>
              int.tryParse(
                RegExp('$key:\\s+(\\d+)').firstMatch(output)?.group(1) ?? '',
              ) ??
              0;
          available =
              (pages('Pages free') +
                  pages('Pages inactive') +
                  pages('Pages speculative')) *
              page;
        }
      }
    } catch (_) {
      /* Total memory is still useful; headroom stays unknown. */
    }
    return ModelHardware(
      appleSilicon: arm,
      memoryBytes: total,
      availableBytes: available,
      detail: arm
          ? 'Apple Silicon · unified memory. Available memory is an OS free/reclaimable estimate.'
          : 'Intel Mac: current managed MLX catalog cannot load these models.',
    );
  } catch (_) {
    return const ModelHardware(
      appleSilicon: false,
      detail: 'Hardware detection failed. No compatibility claim can be made.',
    );
  }
}
