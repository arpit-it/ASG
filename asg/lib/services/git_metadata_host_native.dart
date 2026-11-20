// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../models/git_head_observation.dart';
import 'git_metadata_host.dart';

/// Injectable only for deterministic lifecycle tests; production uses Process.start.
typedef GitMetadataProcessStarter = Future<Process> Function(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required bool runInShell,
  required bool includeParentEnvironment,
  required Map<String, String> environment,
});

Future<Process> _start(
  String executable,
  List<String> arguments, {
  required String workingDirectory,
  required bool runInShell,
  required bool includeParentEnvironment,
  required Map<String, String> environment,
}) => Process.start(
  executable,
  arguments,
  workingDirectory: workingDirectory,
  runInShell: runInShell,
  includeParentEnvironment: includeParentEnvironment,
  environment: environment,
);

GitMetadataHost createGitMetadataHost() => NativeGitMetadataHost();

const _failed =
    'Git metadata inspection failed. Check the selected folder and configured absolute Python path.';
const _stopped = 'Git metadata inspection stopped or exceeded its deadline.';
const _cleanupFailed = 'Git metadata helper cleanup could not be confirmed.';

class _ReadJob {
  _ReadJob() {
    // Keep the original futures observable while also draining disposal races.
    unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    unawaited(
      done.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }
  final result = Completer<GitHeadObservation>();
  final done = Completer<void>(), stop = Completer<void>();
  Timer? timer;
  Process? process;
  Future<int>? exit;
  bool exited = false;
  Directory? temp;
  bool get stopped => stop.isCompleted;
  void check() {
    if (stopped) throw StateError(_stopped);
  }

  void interrupt() {
    if (!stop.isCompleted) stop.complete();
    if (!result.isCompleted) result.completeError(StateError(_stopped));
  }
}

/// Runs only the packaged, command-free reader. No Git or runtime process reuse.
class NativeGitMetadataHost implements GitMetadataHost {
  NativeGitMetadataHost({
    Future<String> Function()? loadAsset,
    Future<Directory> Function()? createTemp,
    GitMetadataProcessStarter? startProcess,
    bool? platformSupported,
    Timer Function(Duration, void Function())? createTimer,
    this.deadline = const Duration(seconds: 10),
  }) : _loadAsset =
           loadAsset ??
           (() => rootBundle.loadString('tools/git_head_metadata.py')),
       _createTemp =
           createTemp ??
           (() => Directory.systemTemp.createTemp('asg-git-metadata-')),
       _startProcess = startProcess ?? _start,
       _supported = platformSupported ?? Platform.isMacOS,
       _createTimer = createTimer ?? Timer.new;

  final Future<String> Function() _loadAsset;
  final Future<Directory> Function() _createTemp;
  final GitMetadataProcessStarter _startProcess;
  final bool _supported;
  final Timer Function(Duration, void Function()) _createTimer;
  final Duration deadline;
  _ReadJob? _job;
  bool _disposed = false;
  @override
  bool get supported => _supported;

  bool _inside(String root, String value) =>
      path.equals(root.toLowerCase(), value.toLowerCase()) ||
      path.isWithin(root.toLowerCase(), value.toLowerCase());

  Future<String> _inputs(GitMetadataReadRequest request) async {
    for (final value in [request.root, request.python]) {
      if (!path.isAbsolute(value) ||
          path.normalize(value) != value ||
          utf8.encode(value).length > 4096 ||
          value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw const FormatException();
      }
    }
    if (request.root == path.separator ||
        _inside(request.root, request.python) ||
        await FileSystemEntity.type(request.root, followLinks: false) !=
            FileSystemEntityType.directory ||
        await Directory(request.root).resolveSymbolicLinks() != request.root) {
      throw const FormatException();
    }
    final python = await File(request.python).resolveSymbolicLinks();
    final info = await File(python).stat();
    if (!path.isAbsolute(python) ||
        _inside(request.root, python) ||
        info.type != FileSystemEntityType.file ||
        info.mode & 0x49 == 0) {
      throw const FormatException();
    }
    return python;
  }

  @override
  Future<GitHeadObservation> inspect(GitMetadataReadRequest request) {
    if (!_supported || _disposed || _job != null || deadline <= Duration.zero) {
      return Future.error(StateError(_failed));
    }
    final job = _ReadJob();
    _job = job;
    job.timer = _createTimer(deadline, job.interrupt);
    unawaited(_execute(job, request));
    return job.result.future;
  }

  Future<GitHeadObservation> _capture(_ReadJob job, Process process) async {
    final output = BytesBuilder(copy: false),
        errors = BytesBuilder(copy: false);
    final failure = Completer<Never>();
    final subscriptions = <StreamSubscription<List<int>>>[];
    final ends = <Future<void>>[];
    void fail(Object _, [StackTrace? _]) {
      if (!failure.isCompleted) failure.completeError(StateError(_failed));
    }

    final failed = failure.future;
    unawaited(failed.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    try {
      for (final (stream, buffer) in [
        (process.stdout, output),
        (process.stderr, errors),
      ]) {
        final end = Completer<void>();
        ends.add(end.future);
        subscriptions.add(
          stream.listen(
            (chunk) {
              if (failure.isCompleted || job.stopped) return;
              if (chunk.length > 4096 - buffer.length) {
                fail(StateError(_failed));
                return;
              }
              buffer.add(chunk);
            },
            onError: fail,
            onDone: end.complete,
          ),
        );
      }
      final complete = () async {
        final code = await job.exit!;
        await Future.wait(ends);
        if (code != 0 || errors.length != 0) throw StateError(_failed);
        return GitHeadObservation.parse(utf8.decode(output.takeBytes()));
      }();
      return await Future.any([
        complete,
        failed,
        job.stop.future.then<GitHeadObservation>(
          (_) => throw StateError(_stopped),
        ),
      ]);
    } finally {
      await Future.wait(subscriptions.map((s) => s.cancel()));
    }
  }

  Future<void> _execute(_ReadJob job, GitMetadataReadRequest request) async {
    GitHeadObservation? value;
    Object? failure;
    var cleaned = false;
    try {
      final python = await _inputs(request);
      job.check();
      final asset = await _loadAsset();
      job.check();
      final created = await _createTemp();
      // A rejected injected/foreign directory is never adopted for deletion.
      if (await FileSystemEntity.type(created.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FormatException();
      }
      final temp = Directory(await created.resolveSymbolicLinks());
      if (_inside(request.root, temp.path) ||
          (await temp.stat()).mode & 0x3f != 0 ||
          !await temp.list(followLinks: false).isEmpty) {
        throw const FormatException();
      }
      job.temp = temp;
      job.check();
      final helper = File(path.join(temp.path, 'git_head_metadata.py'));
      await helper.writeAsString(asset, flush: true);
      job.check();
      if (await _inputs(request) != python) throw const FormatException();
      job.check();
      final process = await _startProcess(
        python,
        ['-I', '-S', '-B', helper.path, '--root', request.root],
        workingDirectory: temp.path,
        runInShell: false,
        includeParentEnvironment: false,
        environment: const {},
      );
      job.process = process;
      job.exit = process.exitCode.then((code) {
        job.exited = true;
        return code;
      });
      // Even a late startup is captured and then killed/reaped by this job.
      value = await _capture(job, process);
      job.check();
    } catch (_) {
      failure = StateError(job.stopped ? _stopped : _failed);
    } finally {
      try {
        final process = job.process;
        if (process != null) {
          if (!job.exited) process.kill(ProcessSignal.sigkill);
          await job.exit;
        }
        final temp = job.temp;
        if (temp != null) {
          if (await FileSystemEntity.type(temp.path, followLinks: false) !=
                  FileSystemEntityType.directory ||
              await temp.resolveSymbolicLinks() != temp.path) {
            throw const FileSystemException();
          }
          final helper = File(path.join(temp.path, 'git_head_metadata.py'));
          if (await FileSystemEntity.type(helper.path, followLinks: false) !=
              FileSystemEntityType.notFound) {
            await helper.delete();
          }
          // Never recursively delete unexpected entries or a retargeted directory.
          await temp.delete();
        }
        cleaned = true;
      } catch (_) {
        failure = StateError(_cleanupFailed);
      }
      job.timer?.cancel();
      if (!job.result.isCompleted) {
        if (failure != null || value == null) {
          job.result.completeError(failure ?? StateError(_failed));
        } else {
          job.result.complete(value);
        }
      }
      if (cleaned) {
        if (identical(_job, job)) _job = null;
        job.done.complete();
      } else {
        // Failed cleanup is sticky: a later operation cannot overlap unknown work.
        job.done.completeError(StateError(_cleanupFailed));
      }
    }
  }

  @override
  Future<void> cancel() async {
    final job = _job;
    if (job == null) return;
    job.interrupt();
    try {
      await job.done.future;
    } catch (_) {
      throw StateError(_cleanupFailed);
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    await cancel();
  }
}
