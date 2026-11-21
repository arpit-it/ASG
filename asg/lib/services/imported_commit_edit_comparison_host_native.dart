// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as path;

import '../models/imported_commit_edit_comparison.dart';
import 'imported_commit_edit_comparison_host.dart';

/// Injectable only for deterministic lifecycle tests; production uses Process.start.
typedef ImportedCommitEditComparisonProcessStarter = Future<Process> Function(
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

ImportedCommitEditComparisonHost createImportedCommitEditComparisonHost() =>
    NativeImportedCommitEditComparisonHost();

const _failed =
    'Proposed-copy comparison could not be confirmed. Inspect the destination before retrying.';
const _stopped =
    'Proposed-copy comparison stopped or exceeded its deadline. Inspect the destination.';
const _cleanupFailed =
    'Recheck worker cleanup could not be confirmed. New work remains blocked.';
const _assets = [
  'imported_commit_edit_comparison.py',
  'prepare_self_candidate.py',
];

class _CopyJob {
  _CopyJob() {
    // Keep the original futures observable while also draining disposal races.
    unawaited(
      result.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    unawaited(
      done.future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
  }
  final result = Completer<ImportedCommitEditComparisonObservation>();
  final done = Completer<void>(), stop = Completer<void>();
  Timer? timer;
  Process? process;
  Future<int>? exit;
  bool exited = false, cleanupUncertain = false, sessionConfirmed = false;
  Directory? temp;
  Future<void>? reaping;
  bool get stopped => stop.isCompleted;
  void check() {
    if (stopped) throw StateError(_stopped);
  }

  void interrupt() {
    if (!stop.isCompleted) stop.complete();
  }
}

/// Runs only trusted bundled read-only recheck tools in an owned process group.
/// It never runs repository commands or applies a proposal or changes copy/source files. Not an OS sandbox.
class NativeImportedCommitEditComparisonHost
    implements ImportedCommitEditComparisonHost {
  NativeImportedCommitEditComparisonHost({
    Future<Map<String, String>> Function()? loadAssets,
    Future<Directory> Function()? createTemp,
    ImportedCommitEditComparisonProcessStarter? startProcess,
    bool? platformSupported,
    Timer Function(Duration, void Function())? createTimer,
    this.deadline = const Duration(seconds: 90),
    this.cleanupGrace = const Duration(seconds: 2),
    bool Function(int)? groupExists,
    void Function(int)? killGroup,
  }) : _loadAssets =
           loadAssets ??
           (() async => {
             for (final name in _assets)
               name: await rootBundle.loadString('tools/$name'),
           }),
       _createTemp =
           createTemp ??
           (() => Directory.systemTemp.createTemp('asg-commit-comparison-')),
       _startProcess = startProcess ?? _start,
       _supported = platformSupported ?? Platform.isMacOS,
       _createTimer = createTimer ?? Timer.new,
       _groupExists =
           groupExists ?? ((pid) => _ProcessGroups.instance.exists(pid)),
       _killGroup = killGroup ?? ((pid) => _ProcessGroups.instance.kill(pid));

  final Future<Map<String, String>> Function() _loadAssets;
  final Future<Directory> Function() _createTemp;
  final ImportedCommitEditComparisonProcessStarter _startProcess;
  final bool _supported;
  final Timer Function(Duration, void Function()) _createTimer;
  final Duration deadline, cleanupGrace;
  final bool Function(int) _groupExists;
  final void Function(int) _killGroup;
  _CopyJob? _job;
  bool _disposed = false;
  ImportedCommitEditComparisonObservation? _lastObservation;
  @override
  ImportedCommitEditComparisonObservation? get lastObservation =>
      _lastObservation;
  @override
  bool get cleanupConfirmed => _job == null;
  @override
  bool get supported => _supported;

  bool _inside(String root, String value) =>
      path.equals(root.toLowerCase(), value.toLowerCase()) ||
      path.isWithin(root.toLowerCase(), value.toLowerCase());

  Future<String> _inputs(ImportedCommitEditComparisonRequest request) async {
    if (!ImportedCommitEditComparisonRequest.restore(request.requestJson)
        .matches(request)) {
      throw const FormatException();
    }
    for (final destination in [
      request.originalDestination,
      request.proposedDestination,
    ]) {
      if (await FileSystemEntity.type(destination, followLinks: false) !=
              FileSystemEntityType.directory ||
          await Directory(destination).resolveSymbolicLinks() != destination) {
        throw const FormatException();
      }
    }
    final python = await File(request.python).resolveSymbolicLinks();
    final info = await File(python).stat();
    if (!path.isAbsolute(python) ||
        _inside(request.root, python) ||
        _inside(request.originalDestination, python) ||
        _inside(request.proposedDestination, python) ||
        info.type != FileSystemEntityType.file ||
        info.mode & 0x49 == 0) {
      throw const FormatException();
    }
    var directory = path.dirname(python);
    while (directory != path.dirname(directory)) {
      for (final protected in [
        request.originalDestination,
        request.proposedDestination,
      ]) {
        if (await FileSystemEntity.identical(directory, protected)) {
          throw const FormatException();
        }
      }
      directory = path.dirname(directory);
    }
    return python;
  }

  @override
  Future<ImportedCommitEditComparisonObservation> compare(
    ImportedCommitEditComparisonRequest request,
  ) {
    if (!_supported ||
        _disposed ||
        _job != null ||
        deadline <= Duration.zero ||
        cleanupGrace <= Duration.zero) {
      return Future.error(StateError(_failed));
    }
    _lastObservation = null;
    final job = _CopyJob();
    _job = job;
    job.timer = _createTimer(deadline, job.interrupt);
    unawaited(_execute(job, request));
    return job.result.future;
  }

  Future<ImportedCommitEditComparisonObservation> _capture(
    _CopyJob job,
    Process process,
    ImportedCommitEditComparisonRequest request,
  ) async {
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
      for (final (stream, buffer, limit) in [
        (
          process.stdout,
          output,
          ImportedCommitEditComparisonObservation.responseLimit,
        ),
        (process.stderr, errors, 4096),
      ]) {
        final end = Completer<void>();
        ends.add(end.future);
        subscriptions.add(
          stream.listen(
            (chunk) {
              if (failure.isCompleted) return;
              if (chunk.length > limit - buffer.length) {
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
        if ((code != 0 && code != 2) || errors.length != 0) {
          throw StateError(_failed);
        }
        final observation = ImportedCommitEditComparisonObservation.fromJson(
          utf8.decode(output.takeBytes()),
          request: request,
        );
        if ((code == 0) !=
            (observation.status !=
                ImportedCommitEditComparisonStatus.refused)) {
          throw StateError(_failed);
        }
        return observation;
      }();
      // Continue draining the bounded receipt after Stop while owned cleanup
      // settles. A late prepared receipt is retained as recovery data only.
      unawaited(
        job.stop.future.then<void>((_) => _reap(job, process)).catchError(fail),
      );
      return await Future.any([complete, failed]);
    } finally {
      await Future.wait(subscriptions.map((s) => s.cancel()));
    }
  }

  Future<void> _execute(
    _CopyJob job,
    ImportedCommitEditComparisonRequest request,
  ) async {
    ImportedCommitEditComparisonObservation? value;
    Object? failure;
    var cleaned = false;
    try {
      job.check();
      final python = await _inputs(request);
      job.check();
      final assets = await _loadAssets();
      if (assets.length != _assets.length ||
          _assets.any(
            (name) =>
                !assets.containsKey(name) ||
                utf8.encode(assets[name]!).length > 1024 * 1024,
          )) {
        throw const FormatException();
      }
      job.check();
      final created = await _createTemp();
      // A rejected injected/foreign directory is never adopted for deletion.
      if (await FileSystemEntity.type(created.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        throw const FormatException();
      }
      final temp = Directory(await created.resolveSymbolicLinks());
      if (_inside(request.root, temp.path) ||
          _inside(request.originalDestination, temp.path) ||
          _inside(request.proposedDestination, temp.path) ||
          (await temp.stat()).mode & 0x3f != 0 ||
          !await temp.list(followLinks: false).isEmpty) {
        throw const FormatException();
      }
      job.temp = temp;
      job.check();
      for (final name in _assets) {
        final helper = File(path.join(temp.path, name));
        await helper.create(exclusive: true);
        await helper.writeAsString(assets[name]!, flush: true);
      }
      final payload = File(path.join(temp.path, 'request.json'));
      await payload.create(exclusive: true);
      await payload.writeAsString(request.requestJson, flush: true);
      final entry = File(
        path.join(temp.path, 'imported_commit_edit_comparison_entry.py'),
      );
      await entry.create(exclusive: true);
      await entry.writeAsString(_entry, flush: true);
      job.check();
      if (await _inputs(request) != python) throw const FormatException();
      job.check();
      final process = await _startProcess(
        python,
        ['-I', '-S', '-B', entry.path, payload.path],
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
      value = await _capture(job, process, request);
      if (!await _session(job, process.pid)) throw const FormatException();
      // A request-bound receipt from the owned session remains useful when
      // subsequent physical validation fails; it is never current success then.
      _lastObservation = value;
      await _validateObservation(value, request);
      job.check();
    } catch (_) {
      failure = StateError(job.stopped ? _stopped : _failed);
    } finally {
      try {
        final process = job.process;
        if (process != null) await _reap(job, process);
        if (job.cleanupUncertain) throw StateError(_cleanupFailed);
        final temp = job.temp;
        if (temp != null) {
          if (await FileSystemEntity.type(temp.path, followLinks: false) !=
                  FileSystemEntityType.directory ||
              await temp.resolveSymbolicLinks() != temp.path) {
            throw const FileSystemException();
          }
          for (final name in [
            ..._assets,
            'imported_commit_edit_comparison_entry.py',
            'request.json',
            'comparison-session',
            'comparison-session.pending',
          ]) {
            final file = File(path.join(temp.path, name));
            final type = await FileSystemEntity.type(
              file.path,
              followLinks: false,
            );
            if (type != FileSystemEntityType.notFound) {
              if (type != FileSystemEntityType.file) {
                throw const FileSystemException();
              }
              await file.delete();
            }
          }
          // Never recursively delete unexpected entries or a retargeted directory.
          await temp.delete();
        }
        cleaned = true;
      } catch (_) {
        failure = StateError(_cleanupFailed);
      }
      job.timer?.cancel();
      // Stop can arrive while final process-group or file cleanup is awaiting.
      // The retained receipt is then recovery evidence, never current success.
      if (job.stopped && cleaned) failure = StateError(_stopped);
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

  Future<bool> _session(_CopyJob job, int pid) async {
    if (pid <= 1) throw StateError(_cleanupFailed);
    final temp = job.temp;
    if (temp == null ||
        await temp.resolveSymbolicLinks() != temp.path ||
        await FileSystemEntity.type(temp.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw StateError(_cleanupFailed);
    }
    final marker = File(path.join(temp.path, 'comparison-session'));
    final type = await FileSystemEntity.type(marker.path, followLinks: false);
    if (type == FileSystemEntityType.notFound) {
      if (job.sessionConfirmed) throw StateError(_cleanupFailed);
      return false;
    }
    if (type != FileSystemEntityType.file) throw StateError(_cleanupFailed);
    final file = await marker.open();
    try {
      final bytes = await file.read(32);
      if (utf8.decode(bytes) != pid.toString() ||
          await file.length() != bytes.length) {
        throw StateError(_cleanupFailed);
      }
      job.sessionConfirmed = true;
      return true;
    } finally {
      await file.close();
    }
  }

  Future<void> _validateObservation(
    ImportedCommitEditComparisonObservation value,
    ImportedCommitEditComparisonRequest request,
  ) async {
    if (value.status == ImportedCommitEditComparisonStatus.refused) return;
    for (final (destination, run, copy) in [
      (request.originalDestination, request.originalRun, request.originalCopy),
      (request.proposedDestination, request.proposedRun, request.proposedCopy),
    ]) {
      final parent = path.join(destination, run);
      for (final directory in [destination, parent, copy]) {
        if (await FileSystemEntity.type(directory, followLinks: false) !=
                FileSystemEntityType.directory ||
            await Directory(directory).resolveSymbolicLinks() != directory) {
          throw const FormatException();
        }
      }
      if ((await Directory(parent).stat()).mode & 0x3f != 0) {
        throw const FormatException();
      }
      for (final marker in [
        '.asg-preparation-pending',
        '.asg-imported-copy-pending',
        '.asg-imported-edit-pending',
      ]) {
        if (await FileSystemEntity.type(
              path.join(parent, marker),
              followLinks: false,
            ) !=
            FileSystemEntityType.notFound) {
          throw const FormatException();
        }
      }
    }
  }

  Future<void> _reap(_CopyJob job, Process process) =>
      job.reaping ??= _reapOwned(job, process);

  Future<void> _reapOwned(_CopyJob job, Process process) async {
    if (!job.exited) {
      process.kill(ProcessSignal.sigterm);
      try {
        await job.exit!.timeout(cleanupGrace);
      } on TimeoutException {
        // Session marker precedes all bundled tool entry and Git child startup.
        // Give its finally blocks grace to kill/reap children before group kill.
        if (await _session(job, process.pid)) _killGroup(process.pid);
        if (!job.exited) process.kill(ProcessSignal.sigkill);
        await job.exit!.timeout(cleanupGrace);
      }
    }
    final session = await _session(job, process.pid);
    if (session && _groupExists(process.pid)) {
      _killGroup(process.pid);
      final elapsed = Stopwatch()..start();
      while (_groupExists(process.pid)) {
        if (elapsed.elapsed >= cleanupGrace) throw StateError(_cleanupFailed);
        await Future<void>.delayed(const Duration(milliseconds: 10));
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

// Loaded only by a supported native host, never by the browser/stub path.
class _ProcessGroups {
  _ProcessGroups()
    : _kill = DynamicLibrary.process()
          .lookupFunction<Int32 Function(Int32, Int32), int Function(int, int)>(
            'kill',
            isLeaf: true,
          ),
      _errno = DynamicLibrary.process()
          .lookupFunction<Pointer<Int32> Function(), Pointer<Int32> Function()>(
            Platform.isMacOS ? '__error' : '__errno_location',
            isLeaf: true,
          );
  static final instance = _ProcessGroups();
  final int Function(int, int) _kill;
  final Pointer<Int32> Function() _errno;
  bool exists(int pid) {
    if (pid <= 1) throw StateError(_cleanupFailed);
    if (_kill(-pid, 0) == 0) return true;
    if (_errno().value == 3) return false; // ESRCH: no owned process group.
    throw StateError(_cleanupFailed);
  }

  void kill(int pid) {
    if (pid <= 1) throw StateError(_cleanupFailed);
    if (_kill(-pid, 9) == 0 || _errno().value == 3) return;
    throw StateError(_cleanupFailed);
  }
}

const _entry = r'''import os, runpy
os.setsid()
marker = os.path.join(os.path.dirname(__file__), 'comparison-session')
pending = marker + '.pending'
fd = os.open(pending, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
with os.fdopen(fd, 'w') as target:
    target.write(str(os.getpid()))
    target.flush()
    os.fsync(target.fileno())
# Publish a complete session identity atomically without replacing another entry.
os.link(pending, marker)
os.unlink(pending)
runpy.run_path(os.path.join(os.path.dirname(__file__), 'imported_commit_edit_comparison.py'), run_name='__main__')
''';
