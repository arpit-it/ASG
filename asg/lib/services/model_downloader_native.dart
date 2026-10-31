// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:io';

import '../models/model_download.dart';

/// Owns only the download helper, never the inference process.
class NativeModelDownloader {
  final _events = StreamController<ModelDownloadProgress>.broadcast();
  Stream<ModelDownloadProgress> get events => _events.stream;
  ModelDownloadProgress progress = const ModelDownloadProgress();
  Process? _process;
  Future<void>? _finished;
  DownloadPhase? _interruption;
  bool _reserved = false;
  Future<void> Function()? _closeOutput;
  void _publish(ModelDownloadProgress value) {
    progress = value;
    _events.add(value);
  }

  Future<void> run(
    String python,
    String script,
    String repository,
    String revision,
    String destination, {
    bool resume = false,
    Duration timeout = const Duration(hours: 6),
  }) async {
    if (_reserved) throw StateError('A model transfer is already active.');
    final elapsed = Stopwatch()..start();
    _reserved = true;
    _interruption = null;
    _publish(const ModelDownloadProgress(phase: DownloadPhase.starting));
    final done = Completer<void>();
    _finished = done.future;
    StreamSubscription<List<int>>? output, errors;
    try {
      final process = await Process.start(python, [
        '-u',
        script,
        '--repository',
        repository,
        '--revision',
        revision,
        '--destination',
        destination,
        if (resume) '--resume',
      ], runInShell: false);
      _process = process;
      // Bounded incremental framing: arbitrary output cannot grow a line buffer.
      var line = '', overflow = false;
      final outputDone = Completer<void>(), errorsDone = Completer<void>();
      output = process.stdout.listen(
        (chunk) {
          for (final byte in chunk) {
            if (byte == 10) {
              if (!overflow && _interruption == null) {
                final parsed = ModelDownloadProgress.parse(line);
                if (parsed != null) {
                  _publish(parsed);
                } else if (line == '{"v":1,"event":"missing_dependency"}') {
                  _publish(
                    progress.withPhase(
                      DownloadPhase.starting,
                      problem: 'Selected Python needs huggingface_hub. Choose an existing MLX environment or install it in your selected environment.',
                    ),
                  );
                }
              }
              line = '';
              overflow = false;
            } else if (line.length < 1024 && byte < 128) {
              line += String.fromCharCode(byte);
            } else {
              overflow = true;
            }
          }
        },
        onError: (_) {},
        onDone: outputDone.complete,
      );
      errors = process.stderr.listen(
        (_) {},
        onError: (_) {},
        onDone: errorsDone.complete,
      );
      _closeOutput = () async {
        await output?.cancel();
        await errors?.cancel();
        if (!outputDone.isCompleted) outputDone.complete();
        if (!errorsDone.isCompleted) errorsDone.complete();
      };
      if (_interruption != null) process.kill(ProcessSignal.sigterm);
      int code;
      try {
        code = await process.exitCode.timeout(timeout);
      } on TimeoutException {
        await _terminate(process);
        rethrow;
      }
      // A descendant may inherit pipes after the helper exits. Neither normal
      // completion nor Stop may wait indefinitely for those unrelated handles.
      final remaining = timeout - elapsed.elapsed;
      final drainLimit = remaining < const Duration(seconds: 2)
          ? (remaining.isNegative ? Duration.zero : remaining)
          : const Duration(seconds: 2);
      try {
        await Future.wait([outputDone.future, errorsDone.future])
            .timeout(drainLimit);
      } on TimeoutException {
        await _closeOutput?.call();
        if (_interruption == null) rethrow;
      }
      if (_interruption != null) {
        _publish(progress.withPhase(_interruption!));
        throw const DownloadInterrupted();
      }
      if (code != 0) {
        throw StateError(
          progress.problem ?? 'Download failed. Verify Python dependencies, network, permissions and the matching partial-download destination, then Resume.',
        );
      }
      _publish(
        ModelDownloadProgress(
          phase: DownloadPhase.complete,
          bytes: progress.total ?? progress.bytes,
          total: progress.total,
        ),
      );
    } on DownloadInterrupted {
      rethrow;
    } catch (_) {
      _publish(
        progress.withPhase(
          DownloadPhase.failed,
          problem: progress.problem ?? 'Download failed. Check Python dependencies, network and destination. Resume retains matching partial files.',
        ),
      );
      rethrow;
    } finally {
      await output?.cancel();
      await errors?.cancel();
      _closeOutput = null;
      _process = null;
      _reserved = false;
      done.complete();
    }
  }

  Future<void> _terminate(Process process) async {
    process.kill(ProcessSignal.sigterm);
    try {
      await process.exitCode.timeout(const Duration(seconds: 2));
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      await process.exitCode;
    }
  }

  Future<void> interrupt({required bool pause}) async {
    if (!_reserved || _interruption != null) return;
    _interruption = pause ? DownloadPhase.paused : DownloadPhase.stopped;
    _publish(
      progress.withPhase(
        pause ? DownloadPhase.pausing : DownloadPhase.stopping,
      ),
    );
    final process = _process;
    if (process != null) await _terminate(process);
    await _closeOutput?.call();
    await _finished;
  }
}
