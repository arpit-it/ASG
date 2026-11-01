// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/models/cpu_checkpoint_inspection.dart';
import 'package:asg/models/runtime_capabilities.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/cpu_checkpoint_inspection_host.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'runtime_capabilities_test.dart' as discovery;
import 'runtime_setup_test.dart' as fixture;

class InspectionHost extends fixture.FakeRuntimeHost
    implements CpuCheckpointInspectionHost {
  InspectionHost({super.supported});
  int inspections = 0, preparations = 0;
  bool fail = false, occupied = false;
  Completer<void>? gate, prepareGate;
  String? python, path;
  int? ceiling;
  @override
  bool get working => occupied;

  @override
  Future<RuntimeCapabilities> discover(String python) async =>
      RuntimeCapabilities.fromJson(discovery.report());

  @override
  Future<void> prepare(
    String python, {
    RuntimeBackend backend = RuntimeBackend.auto,
  }) async {
    preparations++;
    await prepareGate?.future;
  }

  @override
  Future<CpuCheckpointInspection> inspectCpuCheckpoint(
    String python,
    String modelPath, {
    required bool experimentalCpu,
    int? maxWeightBytes,
  }) async {
    expect(experimentalCpu, isTrue);
    inspections++;
    this.python = python;
    path = modelPath;
    ceiling = maxWeightBytes;
    await gate?.future;
    if (fail) throw StateError('PRIVATE_CPU /private/checkpoint token=secret');
    return CpuCheckpointInspection.fromJson({
      'schema_version': 1,
      'backend': 'torch',
      'device': 'cpu',
      'experimental': true,
      'readiness': 'unverified',
      'checkpoint_structure': 'validated',
      'model_compatible': null,
      'memory_adequate': null,
      'inference_verified': false,
      'weight_bytes': 1234,
      'weight_file_count': 2,
    });
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('inspection rejects invalid consent, paths and exact-byte bounds before host work', () async {
    final host = InspectionHost();
    final c = await fixture.controller(host);
    addTearDown(c.dispose);
    await c.inspectCpuCheckpoint('/python', '/model', experimentalCpu: false);
    expect(c.error, contains('consent'));
    for (final inputs in [(' ', '/model'), ('/python', ' ')]) {
      await c.inspectCpuCheckpoint(inputs.$1, inputs.$2, experimentalCpu: true);
      expect(c.error, isNotNull);
    }
    for (final ceiling in [-1, 0, 9007199254740992]) {
      await c.inspectCpuCheckpoint(
        '/python',
        '/model',
        experimentalCpu: true,
        maxWeightBytes: ceiling,
      );
      expect(c.error, isNotNull);
    }
    expect(host.inspections, 0);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test(
    'inspection requires supported optional host and respects host busy state',
    () async {
      for (final host in [
        fixture.FakeRuntimeHost(),
        InspectionHost(supported: false),
        InspectionHost()..occupied = true,
      ]) {
        final c = await fixture.controller(host);
        await c.inspectCpuCheckpoint(
          '/python',
          '/model',
          experimentalCpu: true,
        );
        if (!host.working) expect(c.error, contains('unavailable'));
        if (host is InspectionHost) expect(host.inspections, 0);
        c.dispose();
      }
    },
  );

  test('inspection exposes structural bytes only, forwards trimmed inputs and preserves connection', () async {
    final host = InspectionHost()..ownsProcess = true;
    final c = await fixture.controller(
      host,
      api: fixture.connection(ready: () => true),
    );
    addTearDown(c.dispose);
    await c.refresh();
    final setup = c.setup, config = c.connectionConfig, health = c.health;
    await c.discover('/python');
    expect(c.memory, isNotNull);
    await c.inspectCpuCheckpoint(
      ' /python with spaces ',
      ' /checkpoint with spaces ',
      experimentalCpu: true,
      maxWeightBytes: 9007199254740991,
    );
    expect(host.python, '/python with spaces');
    expect(host.path, '/checkpoint with spaces');
    expect(host.ceiling, 9007199254740991);
    expect(c.cpuCheckpointInspection!.weightBytes, 1234);
    expect(c.cpuCheckpointInspection!.weightFileCount, 2);
    expect(c.status, contains(CpuCheckpointInspection.scope));
    expect(c.capabilities, isNull);
    expect(c.memory, isNull);
    expect(c.health, same(health));
    expect(c.setup, same(setup));
    expect(c.connectionConfig, same(config));
    expect(host.ownsProcess, isTrue);
    expect(host.stops, 0);
    expect(host.downloads, 0);
    expect((await SharedPreferences.getInstance()).getKeys(), isEmpty);
  });

  test('new inspection clears prior report; private failure permits retry without a ceiling', () async {
    final host = InspectionHost();
    final c = await fixture.controller(host);
    addTearDown(c.dispose);
    await c.inspectCpuCheckpoint('/python', '/model', experimentalCpu: true);
    expect(c.cpuCheckpointInspection, isNotNull);
    host.fail = true;
    await c.inspectCpuCheckpoint('/python', '/other', experimentalCpu: true);
    expect(c.cpuCheckpointInspection, isNull);
    expect(c.error, contains('retry'));
    expect(c.error, isNot(contains('PRIVATE_CPU')));
    expect(c.error, isNot(contains('/private/')));
    host.fail = false;
    await c.inspectCpuCheckpoint('/python', '/other', experimentalCpu: true);
    expect(host.ceiling, isNull);
    expect(c.error, isNull);
    expect(c.cpuCheckpointInspection, isNotNull);
    c.invalidateCapabilities();
    expect(c.cpuCheckpointInspection, isNull);
    await c.inspectCpuCheckpoint('/python', '/model', experimentalCpu: true);
    await c.inspect('/changed');
    expect(c.cpuCheckpointInspection, isNull);
  });

  for (final fail in [false, true]) {
    for (final dispose in [false, true]) {
      test(
        'inspection suppresses stale completion, fail=$fail dispose=$dispose',
        () async {
          final host = InspectionHost()
            ..gate = Completer<void>()
            ..fail = fail;
          final c = await fixture.controller(host);
          final pending = c.inspectCpuCheckpoint(
            '/python',
            '/model',
            experimentalCpu: true,
          );
          expect(c.busy, isTrue);
          await c.inspectCpuCheckpoint(
            '/python',
            '/duplicate',
            experimentalCpu: true,
          );
          await c.prepare('/python');
          expect(host.inspections, 1);
          expect(host.preparations, 0);
          if (dispose) {
            c.dispose();
          } else {
            c.invalidateCapabilities();
          }
          final status = c.status;
          host.gate!.complete();
          await pending;
          expect(c.cpuCheckpointInspection, isNull);
          expect(c.error, isNull);
          expect(c.status, status);
          if (!dispose) c.dispose();
        },
      );
    }
  }

  test('legacy preparation excludes inspection until it finishes', () async {
    final host = InspectionHost()..prepareGate = Completer<void>();
    final c = await fixture.controller(host);
    addTearDown(c.dispose);
    final pending = c.prepare('/python');
    await c.inspectCpuCheckpoint('/python', '/model', experimentalCpu: true);
    expect(host.inspections, 0);
    host.prepareGate!.complete();
    await pending;
    await c.inspectCpuCheckpoint('/python', '/model', experimentalCpu: true);
    expect(host.inspections, 1);
  });
}
