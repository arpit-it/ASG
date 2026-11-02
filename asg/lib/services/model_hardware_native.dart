// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../models/model_catalog.dart';

Future<ModelHardware> probeModelHardware({
  Future<String> Function(String, List<String>) runProbe = runHardwareProbe,
  bool? isMacOS,
}) async {
  if (!(isMacOS ?? Platform.isMacOS)) {
    return const ModelHardware(
      appleSilicon: false,
      detail: 'Managed model loading currently requires Apple Silicon macOS.',
    );
  }
  try {
    Future<String> sysctl(String key) async {
      return (await runProbe('/usr/sbin/sysctl', ['-n', key])).trim();
    }

    final arm = await sysctl('hw.optional.arm64') == '1';
    final totalText = await sysctl('hw.memsize');
    final rawTotal = RegExp(r'^[0-9]+$').hasMatch(totalText)
        ? int.tryParse(totalText)
        : null;
    final total = rawTotal != null && rawTotal > 0 ? rawTotal : null;
    int? available;
    try {
      final output = await runProbe('/usr/bin/vm_stat', []);
      available = _availableMemory(output, total);
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

/// A missing counter is not a measured zero. Reject ambiguous observations and
/// use wide arithmetic so large counters cannot wrap into plausible headroom.
int? _availableMemory(String output, int? total) {
  if (total == null) return null;
  final lines = output.split('\n').map((line) => line.trimRight()).toList();
  final headers = lines
      .where((line) => line.startsWith('Mach Virtual Memory Statistics:'))
      .toList();
  if (headers.length != 1) return null;
  final header = RegExp(
    r'^Mach Virtual Memory Statistics: \(page size of ([0-9]+) bytes\)$',
  ).firstMatch(headers.single);
  final page = BigInt.tryParse(header?.group(1) ?? '');
  if (page == null || page <= BigInt.zero || page > BigInt.from(total)) {
    return null;
  }
  var pages = BigInt.zero;
  for (final name in ['Pages free', 'Pages inactive', 'Pages speculative']) {
    final counters = lines.where((line) => line.startsWith('$name:')).toList();
    if (counters.length != 1) return null;
    final match = RegExp('^$name:[ \t]+([0-9]+)\\.\$')
        .firstMatch(counters.single);
    final count = BigInt.tryParse(match?.group(1) ?? '');
    if (count == null) return null;
    pages += count;
  }
  final bytes = pages * page;
  return bytes <= BigInt.from(total) ? bytes.toInt() : null;
}

/// Run a fixed read-only hardware helper with bounded output and owned cleanup.
/// Both streams count toward the limit; private stderr is never retained.
Future<String> runHardwareProbe(
  String executable,
  List<String> arguments, {
  Duration timeout = const Duration(seconds: 3),
  int maxOutputBytes = 65536,
  Future<Process> Function(String, List<String>)? start,
}) async {
  final process =
      await (start ??
          (command, args) => Process.start(command, args, runInShell: false))(
        executable,
        arguments,
      );
  var exited = false;
  final exit = process.exitCode.then((code) {
    exited = true;
    return code;
  });
  final bytes = <int>[];
  var received = 0;
  var failed = false;
  final outDone = Completer<void>();
  final errDone = Completer<void>();
  void consume(List<int> chunk, {required bool retain}) {
    if (failed) return;
    received += chunk.length;
    if (received > maxOutputBytes) {
      failed = true;
      process.kill(ProcessSignal.sigkill);
    } else if (retain) {
      bytes.addAll(chunk);
    }
  }

  void streamError(Completer<void> done) {
    failed = true;
    process.kill(ProcessSignal.sigkill);
    if (!done.isCompleted) done.complete();
  }

  final output = process.stdout.listen(
    (chunk) => consume(chunk, retain: true),
    onDone: () {
      if (!outDone.isCompleted) outDone.complete();
    },
    onError: (_) => streamError(outDone),
  );
  final errors = process.stderr.listen(
    (chunk) => consume(chunk, retain: false),
    onDone: () {
      if (!errDone.isCompleted) errDone.complete();
    },
    onError: (_) => streamError(errDone),
  );
  try {
    final results = await Future.wait<Object?>([
      exit,
      outDone.future,
      errDone.future,
    ]).timeout(timeout);
    if (results.first != 0 || failed) throw StateError('Hardware probe failed');
    return utf8.decode(bytes);
  } catch (_) {
    throw StateError('Hardware probe failed or exceeded its limits.');
  } finally {
    try {
      if (!exited) {
        process.kill(ProcessSignal.sigkill);
        await exit.timeout(const Duration(seconds: 2));
      }
    } finally {
      await output.cancel();
      await errors.cancel();
    }
  }
}
