// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import 'generation_process_capture.dart';

bool get supportsSelfSnapshot => Platform.isMacOS;

Future<String> prepareSelfSnapshot({
  required String source,
  required String destination,
  required String commit,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
}) async {
  if (!supportsSelfSnapshot ||
      ![source, destination, python].every(path.isAbsolute) ||
      !RegExp(r'^[a-f0-9]{40}$').hasMatch(commit)) {
    throw const FormatException('Invalid snapshot inputs.');
  }
  final parent = await Directory(destination).resolveSymbolicLinks();
  final temp = await Directory.systemTemp.createTemp('asg-snapshot-helper-');
  Process? process;
  var settled = false;
  try {
    final helper = File(path.join(temp.path, 'prepare_self_candidate.py'));
    await helper.writeAsString(
      await rootBundle.loadString('tools/prepare_self_candidate.py'),
      flush: true,
    );
    if (stopped()) throw StateError('Snapshot stopped.');
    process = await Process.start(
      python,
      ['-I', '-B', helper.path, source, commit, parent],
      runInShell: false,
      includeParentEnvironment: false,
    );
    final owned = process;
    stop.then((_) {
      if (!settled) owned.kill(ProcessSignal.sigkill);
    });
    final result = await captureGenerationProcess(
      owned,
      timeout: const Duration(seconds: 65),
      cancellation: stop,
    );
    settled = true;
    if (stopped() || result.exitCode != 0) {
      throw StateError('Snapshot preparation failed.');
    }
    final output = result.stdout;
    if (!output.endsWith('\n') || output.indexOf('\n') != output.length - 1) {
      throw const FormatException('Unexpected snapshot result.');
    }
    final ready = output.substring(0, output.length - 1);
    final run = path.dirname(ready);
    if (path.dirname(run) != parent ||
        !path.basename(run).startsWith('asg-self-candidate-') ||
        path.basename(ready) != 'source-$commit' ||
        await Directory(ready).resolveSymbolicLinks() != ready) {
      throw const FormatException('Unexpected snapshot directory.');
    }
    return ready;
  } finally {
    if (process != null && !settled) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 3));
    }
    settled = true;
    await temp.delete(recursive: true);
  }
}
