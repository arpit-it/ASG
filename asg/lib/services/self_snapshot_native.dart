// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../models/generation_command_result.dart';
import '../models/self_snapshot_operation.dart';
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
      if (!settled) owned.kill(ProcessSignal.sigterm);
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
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 3));
      }
    }
    settled = true;
    await temp.delete(recursive: true);
  }
}

/// Looks only for the incomplete staging folders created by snapshot runs.
Future<List<String>> inspectIncompleteSnapshots(String destination) async {
  if (!supportsSelfSnapshot || !path.isAbsolute(destination)) {
    throw const FormatException('Invalid snapshot destination.');
  }
  const limit = Duration(seconds: 5);
  final root = await Directory(destination)
      .resolveSymbolicLinks()
      .timeout(limit);
  final elapsed = Stopwatch()..start();
  final found = <String>[];
  final runName = RegExp(r'^asg-self-candidate-[a-z0-9_]{8}$');
  var scanned = 0;
  await for (final entry in Directory(
    root,
  ).list(followLinks: false).timeout(limit)) {
    if (++scanned > 512 || elapsed.elapsed >= limit) {
      throw StateError('Snapshot inspection exceeded its limits.');
    }
    if (entry is! Directory || !runName.hasMatch(path.basename(entry.path))) {
      continue;
    }
    final staging = path.join(entry.path, 'incomplete');
    if (await FileSystemEntity.type(
          staging,
          followLinks: false,
        ).timeout(limit) !=
        FileSystemEntityType.directory) {
      continue;
    }
    if (await Directory(staging).resolveSymbolicLinks().timeout(limit) ==
        staging) {
      if (found.length == 20) {
        throw StateError('Snapshot inspection exceeded its limits.');
      }
      found.add(staging);
    }
  }
  return found..sort();
}

Future<GenerationCommandResult> checkSelfSnapshot({
  required String snapshot,
  required String sdk,
  required String python,
  required SelfSnapshotOperation operation,
  required Future<void> stop,
  required bool Function() stopped,
}) async {
  final run = path.dirname(snapshot);
  if (!supportsSelfSnapshot ||
      ![snapshot, sdk, python].every(path.isAbsolute) ||
      !RegExp(r'^source-[a-f0-9]{40}$').hasMatch(path.basename(snapshot)) ||
      !RegExp(r'^asg-self-candidate-[a-z0-9_]{8}$')
          .hasMatch(path.basename(run)) ||
      await Directory(snapshot).resolveSymbolicLinks() != snapshot) {
    throw const FormatException('Select a prepared ASG source snapshot.');
  }
  final project = path.join(snapshot, 'asg');
  final manifest = path.join(project, 'pubspec.yaml');
  if (await Directory(project).resolveSymbolicLinks() != project ||
      await FileSystemEntity.type(manifest, followLinks: false) !=
          FileSystemEntityType.file) {
    throw const FormatException('Snapshot does not contain an ASG project.');
  }
  final temp = await Directory.systemTemp.createTemp('asg-snapshot-check-');
  Process? process;
  var settled = false;
  var signalled = false;
  void terminate(Process owned) {
    if (settled || signalled) return;
    signalled = true;
    owned.kill(ProcessSignal.sigterm);
  }

  try {
    final helper = File(path.join(temp.path, 'generation_command.py'));
    await helper.writeAsString(
      await rootBundle.loadString('tools/generation_command.py'),
      flush: true,
    );
    if (stopped()) throw StateError('Snapshot check stopped.');
    final owned = await Process.start(python, [
      '-I',
      '-B',
      helper.path,
      '--confined',
      '--offline-snapshot-check',
      '--operation',
      operation.name,
      '--sdk',
      sdk,
      '--directory',
      project,
    ], runInShell: false);
    process = owned;
    unawaited(stop.then((_) => terminate(owned)));
    final result = await captureGenerationProcess(
      owned,
      timeout: const Duration(seconds: 190),
      cancellation: stop,
    );
    settled = true;
    if (stopped() || result.exitCode != 0) {
      throw StateError('Snapshot check did not complete.');
    }
    return GenerationCommandResult.decode(result.stdout);
  } finally {
    if (process != null && !settled) {
      terminate(process);
      try {
        await process.exitCode.timeout(const Duration(seconds: 5));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 3));
      }
    }
    settled = true;
    await temp.delete(recursive: true);
  }
}
