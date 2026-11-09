// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../models/candidate_comparison.dart';
import '../models/candidate_source_proposal.dart';
import '../models/candidate_file_review.dart';
import '../models/generation_command_result.dart';
import '../models/self_snapshot_operation.dart';
import '../models/snapshot_preparation_failure.dart';
import 'generation_process_capture.dart';

bool get supportsSelfSnapshot => Platform.isMacOS;

Future<String> fingerprintSelfSnapshot({
  required String snapshot,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
}) async {
  final output = await _readCandidate(
    snapshot: snapshot,
    python: python,
    stop: stop,
    stopped: stopped,
  );
  if (!RegExp(r'^[a-f0-9]{64}\n$').hasMatch(output)) {
    throw const FormatException('Invalid candidate fingerprint.');
  }
  return output.trim();
}

Future<CandidateComparison> compareSelfSnapshot({
  required String snapshot,
  required String source,
  required String commit,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
}) async {
  final output = await _readCandidate(
    snapshot: snapshot,
    source: source,
    commit: commit,
    python: python,
    stop: stop,
    stopped: stopped,
  );
  final comparison = CandidateComparison.decode(output);
  if (comparison.commit != commit) {
    throw const FormatException('Candidate baseline differs from selection.');
  }
  return comparison;
}

Future<CandidateFileReview> reviewSelfSnapshotFile({
  required String snapshot,
  required String source,
  required String commit,
  required String digest,
  required String file,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
}) async {
  if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
    throw const FormatException('Invalid comparison fingerprint.');
  }
  final output = await _readCandidate(
    snapshot: snapshot,
    source: source,
    commit: commit,
    python: python,
    stop: stop,
    stopped: stopped,
    digest: digest,
    file: file,
  );
  final review = CandidateFileReview.decode(output);
  if (review.commit != commit ||
      review.digest != digest ||
      review.path != file) {
    throw const FormatException('File review differs from selection.');
  }
  return review;
}

Future<String> _readCandidate({
  required String snapshot,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
  String? source,
  String? commit,
  String? digest,
  String? file,
}) async {
  if (!supportsSelfSnapshot || ![snapshot, python].every(path.isAbsolute)) {
    throw const FormatException('Invalid candidate inputs.');
  }
  final candidatePath = await Directory(snapshot).resolveSymbolicLinks();
  final interpreter = await File(python).resolveSymbolicLinks();
  if (path.isWithin(candidatePath.toLowerCase(), interpreter.toLowerCase())) {
    throw const FormatException(
      'Choose a trusted Python outside the candidate.',
    );
  }
  String? baseline;
  if (source != null) {
    if (!path.isAbsolute(source) ||
        commit == null ||
        !RegExp(r'^[a-f0-9]{40}$').hasMatch(commit)) {
      throw const FormatException(
        'Select a trusted repository and full commit.',
      );
    }
    baseline = await Directory(source).resolveSymbolicLinks();
    if (path.equals(candidatePath.toLowerCase(), baseline.toLowerCase()) ||
        path.isWithin(candidatePath.toLowerCase(), baseline.toLowerCase())) {
      throw const FormatException(
        'Choose a trusted repository outside the candidate.',
      );
    }
  }
  final temp = await Directory.systemTemp.createTemp('asg-candidate-review-');
  Process? process;
  var settled = false;
  try {
    final helper = File(path.join(temp.path, 'prepare_self_candidate.py'));
    await helper.writeAsString(
      await rootBundle.loadString('tools/prepare_self_candidate.py'),
      flush: true,
    );
    if (stopped()) throw StateError('Candidate review stopped.');
    process = await Process.start(interpreter, [
      '-I',
      '-S',
      '-B',
      helper.path,
      if (file != null)
        '--review-file'
      else if (baseline == null)
        '--fingerprint'
      else
        '--compare',
      snapshot,
      ?baseline,
      ?commit,
      if (file != null) digest!,
      ?file,
    ], includeParentEnvironment: false);
    final owned = process;
    unawaited(
      stop.then((_) {
        if (!settled) owned.kill(ProcessSignal.sigterm);
      }),
    );
    final result = await captureGenerationProcess(
      owned,
      timeout: const Duration(seconds: 30),
      cancellation: stop,
    );
    settled = true;
    if (stopped() || result.exitCode != 0) {
      throw StateError('Candidate fingerprint unavailable.');
    }
    return result.stdout;
  } finally {
    if (!settled && process != null) {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode.timeout(const Duration(seconds: 3));
    }
    settled = true;
    await temp.delete(recursive: true);
  }
}

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
      [
        '-I',
        '-B',
        helper.path,
        '--app-recovery-receipt',
        source,
        commit,
        parent,
      ],
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
    // A settled helper can identify the retained run after a cooperative Stop.
    if (result.exitCode == 1 && result.stdout.isEmpty) {
      final run = await _verifiedFailedRun(parent, result.stderr);
      if (run != null) throw SnapshotPreparationFailure(run);
    }
    if (stopped()) throw StateError('Snapshot stopped.');
    if (result.exitCode != 0) {
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

Future<String?> _verifiedFailedRun(String parent, String receipt) async {
  if (receipt.length > 64 || RegExp(r'[\x00-\x1f\x7f]').hasMatch(parent)) {
    return null;
  }
  final match = RegExp(
    r'^ASG_SNAPSHOT_RECOVERY_V1 (asg-self-candidate-[a-f0-9]{8})\n$',
  ).firstMatch(receipt);
  if (match == null || match.end != receipt.length) return null;
  final run = path.join(parent, match.group(1));
  try {
    if (await FileSystemEntity.type(run, followLinks: false) ==
            FileSystemEntityType.directory &&
        await Directory(run).resolveSymbolicLinks() == run) {
      return run;
    }
  } on FileSystemException {
    // The folder may have moved or disappeared since the helper exited.
  }
  return null;
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
    return GenerationCommandResult.decode(
      result.stdout,
      expectWebArtifact: operation == SelfSnapshotOperation.build,
    );
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

Future<String> canonicalProposalDirectory(String value) =>
    Directory(value).resolveSymbolicLinks().timeout(const Duration(seconds: 5));

Future<CandidateSourceFile> readCandidateProposalSource({
  required String snapshot,
  required String file,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
}) async {
  if (!isCandidateSourcePath(file)) {
    throw const FormatException('Unsupported source path.');
  }
  final output = await _proposalHelper(
    snapshot: snapshot,
    python: python,
    stop: stop,
    stopped: stopped,
    file: file,
  );
  final source = CandidateSourceFile.decode(output);
  if (source.path != file) {
    throw const FormatException('Proposal source differs from selection.');
  }
  return source;
}

Future<CandidateProposalResult> applyCandidateProposal({
  required CandidateSourceProposal proposal,
  required Future<void> stop,
  required bool Function() stopped,
}) async {
  final output = await _proposalHelper(
    snapshot: proposal.snapshot,
    python: proposal.python,
    stop: stop,
    stopped: stopped,
    proposal: proposal,
  );
  final result = CandidateProposalResult.decode(output);
  if (result.sourceDigest != proposal.source.digest ||
      result.file != proposal.source.path ||
      result.afterHash != proposal.afterHash ||
      result.digest == result.sourceDigest ||
      path.dirname(path.dirname(result.path)) != proposal.destination ||
      path.basename(result.path) != path.basename(proposal.snapshot) ||
      path.basename(path.dirname(result.path)) != proposal.runName ||
      await Directory(result.path).resolveSymbolicLinks() != result.path) {
    throw const FormatException(
      'Unverified proposal receipt. Inspect the destination before retrying.',
    );
  }
  return result;
}

Future<String> _proposalHelper({
  required String snapshot,
  required String python,
  required Future<void> stop,
  required bool Function() stopped,
  String? file,
  CandidateSourceProposal? proposal,
}) async {
  if (!supportsSelfSnapshot || ![snapshot, python].every(path.isAbsolute)) {
    throw const FormatException('Invalid proposal inputs.');
  }
  final candidate = await Directory(snapshot).resolveSymbolicLinks();
  final interpreter = await File(python).resolveSymbolicLinks();
  if (path.isWithin(candidate.toLowerCase(), interpreter.toLowerCase())) {
    throw const FormatException('Choose trusted Python outside the candidate.');
  }
  final temporary = await Directory.systemTemp.createTemp(
    'asg-source-proposal-',
  );
  Process? process;
  var settled = false;
  try {
    final helper = File(path.join(temporary.path, 'prepare_self_candidate.py'));
    await helper.writeAsString(
      await rootBundle.loadString('tools/prepare_self_candidate.py'),
      flush: true,
    );
    final arguments = ['-I', '-S', '-B', helper.path];
    if (proposal == null) {
      arguments.addAll(['--proposal-read', snapshot, file!]);
    } else {
      final payload = File(path.join(temporary.path, 'proposal.json'));
      await payload.writeAsString(jsonEncode(proposal.payload), flush: true);
      // Source text is passed only through this private helper directory, never argv.
      arguments.addAll(['--proposal-apply', payload.path]);
    }
    if (stopped()) throw StateError('Proposal stopped.');
    final owned = await Process.start(
      interpreter,
      arguments,
      includeParentEnvironment: false,
    );
    process = owned;
    unawaited(
      stop.then((_) {
        if (!settled) owned.kill(ProcessSignal.sigterm);
      }),
    );
    final result = await captureGenerationProcess(
      owned,
      timeout: const Duration(seconds: 65),
      cancellation: stop,
    );
    settled = true;
    if (stopped() || result.exitCode != 0) {
      throw StateError(
        'Proposal unavailable. Inspect the destination for incomplete or unverified output before retrying.',
      );
    }
    return result.stdout;
  } finally {
    if (!settled && process != null) {
      process.kill(ProcessSignal.sigterm);
      try {
        await process.exitCode.timeout(const Duration(seconds: 3));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
        await process.exitCode.timeout(const Duration(seconds: 3));
      }
    }
    settled = true;
    await temporary.delete(recursive: true);
  }
}
