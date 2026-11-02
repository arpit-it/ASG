// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

@TestOn('mac-os || linux')
library;

import 'dart:convert';
import 'dart:io';

import 'package:asg/services/generation_process_capture.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Future<Process> start(String script, [List<String> arguments = const []]) =>
      Process.start('python3', ['-I', '-B', '-c', script, ...arguments]);
  Future<void> cleanup(Process process) async {
    process.kill(ProcessSignal.sigkill);
    await process.exitCode;
  }

  test(
    'actual exit with retained descendant pipes observes whole deadline',
    () async {
      final folder = await Directory.systemTemp.createTemp(
        'asg retained pipes ',
      );
      final marker = File('${folder.path}/child');
      final process = await start(
        '''import os, sys, time
pid = os.fork()
if pid == 0:
    time.sleep(30)
    os._exit(0)
with open(sys.argv[1], 'w') as stream:
    stream.write(str(pid))
os._exit(0)
''',
        [marker.path],
      );
      int? child;
      try {
        expect(await process.exitCode.timeout(const Duration(seconds: 3)), 0);
        child = int.parse(await marker.readAsString());
        final watch = Stopwatch()..start();
        await expectLater(
          captureGenerationProcess(
            process,
            timeout: const Duration(milliseconds: 200),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'private deadline',
              'Generation helper exceeded its deadline.',
            ),
          ),
        );
        expect(watch.elapsed, lessThan(const Duration(seconds: 3)));
      } finally {
        if (child != null) Process.killPid(child, ProcessSignal.sigkill);
        await cleanup(process);
        await folder.delete(recursive: true);
      }
    },
  );

  test(
    'aggregate stdout and stderr flood refused before exit, retry succeeds',
    () async {
      final process = await start('''import os, time
os.write(1, b'a' * 300000)
os.write(2, b'b' * 300000)
time.sleep(30)
''');
      try {
        await expectLater(
          captureGenerationProcess(
            process,
            timeout: const Duration(seconds: 3),
          ),
          throwsA(
            isA<FormatException>().having(
              (e) => e.message,
              'private ceiling',
              'Generation helper exceeded its output limit.',
            ),
          ),
        );
      } finally {
        await cleanup(process);
      }
      final retry = await start('print("retry")');
      try {
        final result = await captureGenerationProcess(
          retry,
          timeout: const Duration(seconds: 3),
        );
        expect(result.exitCode, 0);
        expect(result.stdout, 'retry\n');
      } finally {
        await cleanup(retry);
      }
    },
  );

  test(
    'valid escaped maximum tool output and split UTF8 preserve protocol',
    () async {
      final process = await start(r'''import json, os
value = json.dumps({'output': chr(0) * 65536, 'text': 'é🤖'}, ensure_ascii=False)
for byte in value.encode('utf-8'):
    os.write(1, bytes([byte]))
os.write(2, b'\xff')
''');
      try {
        final result = await captureGenerationProcess(
          process,
          timeout: const Duration(seconds: 10),
        );
        expect(result.exitCode, 0);
        final value = jsonDecode(result.stdout) as Map<String, dynamic>;
        expect(value['output'], '\u0000' * 65536);
        expect(value['text'], 'é🤖');
        expect(result.stderr, '\ufffd');
      } finally {
        await cleanup(process);
      }
    },
  );

  test(
    'invalid protocol UTF8 is rejected and nonzero stderr retained',
    () async {
      final invalid = await start(r"import os; os.write(1, b'\xff')");
      try {
        await expectLater(
          captureGenerationProcess(
            invalid,
            timeout: const Duration(seconds: 3),
          ),
          throwsFormatException,
        );
      } finally {
        await cleanup(invalid);
      }
      final failure = await start(
        "import sys; sys.stderr.write('tool unavailable'); sys.exit(7)",
      );
      try {
        final result = await captureGenerationProcess(
          failure,
          timeout: const Duration(seconds: 3),
        );
        expect(result.exitCode, 7);
        expect(result.stderr, 'tool unavailable');
      } finally {
        await cleanup(failure);
      }
    },
  );
}
