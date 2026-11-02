// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Captures the helper protocol, including pipe EOF, within one deadline.
/// The caller owns process termination; closing pipes does not prove descendant
/// cleanup. The 512 KiB ceiling accommodates JSON escaping of 64 KiB tool output.
Future<({int exitCode, String stdout, String stderr})> captureGenerationProcess(
  Process process, {
  required Duration timeout,
  Future<void>? cancellation,
}) async {
  const byteLimit = 512 * 1024;
  final output = BytesBuilder(copy: false);
  final error = BytesBuilder(copy: false);
  var captured = 0;
  final failure = Completer<Never>();
  Timer? cancellationDeadline;
  final streams = <StreamSubscription<List<int>>>[];
  final ends = <Future<void>>[];
  void fail(Object reason, [StackTrace? stack]) {
    if (!failure.isCompleted) failure.completeError(reason, stack);
  }

  // Install the error handler before subscribing to either process stream.
  final failed = failure.future;
  final deadline = Timer(timeout, () {
    fail(const FormatException('Generation helper exceeded its deadline.'));
  });
  try {
    for (final entry in [(process.stdout, output), (process.stderr, error)]) {
      final end = Completer<void>();
      ends.add(end.future);
      streams.add(
        entry.$1.listen(
          (chunk) {
            if (failure.isCompleted) return;
            captured += chunk.length;
            if (captured > byteLimit) {
              fail(
                const FormatException(
                  'Generation helper exceeded its output limit.',
                ),
              );
              return;
            }
            entry.$2.add(chunk);
          },
          onError: fail,
          onDone: end.complete,
        ),
      );
    }
    final completed = () async {
      final exitCode = await process.exitCode;
      await Future.wait(ends);
      return (
        exitCode: exitCode,
        stdout: utf8.decode(output.takeBytes()),
        stderr: utf8.decode(error.takeBytes(), allowMalformed: true),
      );
    }();
    var listening = true;
    cancellation?.then((_) {
      if (!listening) return;
      // Give the trusted helper a bounded chance to report cancellation and
      // clean its owned tool group before interrupting protocol capture.
      cancellationDeadline = Timer(const Duration(seconds: 3), () {
        fail(
          StateError(
            'Generation helper capture stopped. Process cleanup is required.',
          ),
        );
      });
    });
    try {
      return await Future.any([completed, failed]);
    } finally {
      listening = false;
    }
  } finally {
    deadline.cancel();
    cancellationDeadline?.cancel();
    await Future.wait(streams.map((stream) => stream.cancel()));
  }
}
