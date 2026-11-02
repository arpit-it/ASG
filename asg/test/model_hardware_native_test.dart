// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:io';

import 'package:asg/services/model_hardware_native.dart';
import 'package:asg/models/model_catalog.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('actual macOS read-only snapshot preserves detected memory', () async {
    final result = await probeModelHardware();
    expect(result.memoryBytes, greaterThan(0));
    expect(result.availableBytes, anyOf(isNull, greaterThanOrEqualTo(0)));
  }, skip: !Platform.isMacOS);

  test(
    'fixed helper captures stdout, discards stderr and checks exit',
    () async {
      expect(
        await runHardwareProbe('/bin/sh', [
          '-c',
          'printf 42; printf PRIVATE >&2',
        ]),
        '42',
      );
      await expectLater(
        runHardwareProbe('/bin/sh', ['-c', 'printf PRIVATE >&2; exit 7']),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'sanitized',
            isNot(contains('PRIVATE')),
          ),
        ),
      );
    },
    skip: Platform.isWindows,
  );
  for (final script in [
    'exec /bin/sleep 30',
    'while :; do printf 1234567890; done',
    'while :; do printf PRIVATE >&2; done',
  ]) {
    test('owned helper is reaped for $script', () async {
      Process? child;
      final clock = Stopwatch()..start();
      await expectLater(
        runHardwareProbe(
          '/bin/sh',
          ['-c', script],
          timeout: script.startsWith('exec')
              ? const Duration(milliseconds: 200)
              : const Duration(seconds: 30),
          maxOutputBytes: 1024,
          start: (executable, arguments) async => child = await Process.start(
            executable,
            arguments,
            runInShell: false,
          ),
        ),
        throwsStateError,
      );
      expect(child, isNotNull);
      expect(
        await child!.exitCode.timeout(const Duration(milliseconds: 200)),
        isNot(0),
      );
      expect(clock.elapsed, lessThan(const Duration(seconds: 3)));
    }, skip: Platform.isWindows);
  }
  test('failed headroom keeps total and normal snapshot remains usable', () async {
    for (final fail in [true, false]) {
      final calls = <List<String>>[];
      final result = await probeModelHardware(
        isMacOS: true,
        runProbe: (command, args) async {
          calls.add([command, ...args]);
          if (command.endsWith('vm_stat')) {
            if (fail) throw StateError('PRIVATE /path');
            return 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 10.\nPages inactive: 20.\nPages speculative: 30.\n';
          }
          return args.last == 'hw.memsize' ? '38654705664\n' : '1\n';
        },
      );
      expect(result.appleSilicon, isTrue);
      expect(result.memoryBytes, 38654705664);
      expect(result.availableBytes, fail ? null : 60 * 16384);
      expect(result.detail, isNot(contains('PRIVATE')));
      expect(calls, [
        ['/usr/sbin/sysctl', '-n', 'hw.optional.arm64'],
        ['/usr/sbin/sysctl', '-n', 'hw.memsize'],
        ['/usr/bin/vm_stat'],
      ]);
    }
  });
  test('malformed memory observations remain unavailable without losing host identity', () async {
    const header = 'Mach Virtual Memory Statistics: (page size of 16384 bytes)';
    const counters =
        'Pages free: 10.\nPages inactive: 20.\nPages speculative: 30.';
    for (final report in [
      header,
      '$header\nPages free: 10.\nPages inactive: 20.',
      '$header\n$counters\nPages free: 9.',
      '$header\n$counters\nPages free: PRIVATE',
      '$header\n${counters.replaceFirst('10.', '10.PRIVATE')}',
      '$header\n${counters.replaceFirst('10.', '-10.')}',
      '$header\n${counters.replaceFirst('10.', '999999999999999999999999999999.')}',
      '${header.replaceFirst('16384', '0')}\n$counters',
      '$header\n$header\n$counters',
      '$header\n${counters.replaceFirst('10.', '3000000.')}',
    ]) {
      final result = await probeModelHardware(
        isMacOS: true,
        runProbe: (command, args) async => command.endsWith('vm_stat')
            ? report
            : args.last == 'hw.memsize'
            ? '38654705664'
            : '1',
      );
      expect(result.appleSilicon, isTrue);
      expect(result.memoryBytes, 38654705664);
      expect(result.availableBytes, isNull, reason: report);
      expect(result.detail, isNot(contains('PRIVATE')));
      final assessment = ModelAssessment.assess(
        result,
        ModelCatalogMetadata(
          revision: 'revision',
          license: 'license',
          architecture: 'Qwen3_5ForConditionalGeneration',
          bits: 4,
          mlxFormat: true,
          weightBytes: gib,
          downloadBytes: gib,
          checkedAt: DateTime.utc(2026),
        ),
      );
      expect(assessment.fit, ModelFit.memoryPressure);
      expect(assessment.detail, contains('unknown'));
    }
  });
  test('nonpositive or overflowing total memory is unknown; real zero headroom is valid', () async {
    for (final total in [
      '0',
      '-1',
      '+38654705664',
      '0x900000000',
      '999999999999999999999999',
      'PRIVATE',
      '38654705664',
    ]) {
      final result = await probeModelHardware(
        isMacOS: true,
        runProbe: (command, args) async => command.endsWith('vm_stat')
            ? 'Mach Virtual Memory Statistics: (page size of 16384 bytes)\nPages free: 0.\nPages inactive: 0.\nPages speculative: 0.\n'
            : args.last == 'hw.memsize'
            ? total
            : '1',
      );
      expect(result.appleSilicon, isTrue);
      expect(result.memoryBytes, total == '38654705664' ? 38654705664 : null);
      expect(result.availableBytes, total == '38654705664' ? 0 : null);
      expect(result.detail, isNot(contains('PRIVATE')));
    }
  });
  test('failed host probe and unsupported hosts never expose errors', () async {
    var calls = 0;
    Future<String> fail(String _, List<String> _) async {
      calls++;
      throw StateError('PRIVATE /path');
    }

    expect(
      (await probeModelHardware(isMacOS: false, runProbe: fail)).memoryBytes,
      isNull,
    );
    expect(calls, 0);
    final unknown = await probeModelHardware(isMacOS: true, runProbe: fail);
    expect(unknown.memoryBytes, isNull);
    expect(unknown.availableBytes, isNull);
    expect(unknown.detail, isNot(contains('PRIVATE')));
    expect(calls, 1);
  });
}
