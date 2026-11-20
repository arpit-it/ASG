// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/project_instruction_controller.dart';
import 'package:asg/models/project_instruction_observation.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/project_instruction_host.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

class InstructionRecords implements RecordStorage {
  final values = <String, String>{};
  int writes = 0;
  @override
  String? getString(String key) => values[key];
  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    values[key] = value;
    return true;
  }
}

ProjectInstructionObservation instructionReply(List<String> paths) =>
    ProjectInstructionObservation.fromJson(
      jsonEncode({
        'version': 1,
        'scope': 'project-instruction-documents',
        'status': 'observed',
        'reason': null,
        'selected_paths': paths,
        'source_verified': false,
        'documents': [
          for (final path in paths)
            {
              'path': path,
              'byte_length': utf8
                  .encode('Untrusted [$path](file://private)\n')
                  .length,
              'sha256': sha256
                  .convert(utf8.encode('Untrusted [$path](file://private)\n'))
                  .toString(),
              'content_base64': base64Encode(
                utf8.encode('Untrusted [$path](file://private)\n'),
              ),
            },
        ],
      }),
    );

class InstructionHost implements ProjectInstructionHost {
  @override
  bool supported = true;
  int reads = 0, cancels = 0, disposals = 0;
  ProjectInstructionReadRequest? request;
  Future<ProjectInstructionObservation> Function(ProjectInstructionReadRequest)?
  onRead;
  Future<void> Function()? onCancel;
  @override
  Future<ProjectInstructionObservation> inspect(
    ProjectInstructionReadRequest value,
  ) async {
    reads++;
    request = value;
    return onRead == null
        ? instructionReply(value.selectedPaths)
        : await onRead!(value);
  }

  @override
  Future<void> cancel() async {
    cancels++;
    await onCancel?.call();
  }

  @override
  Future<void> dispose() async {
    disposals++;
    await cancel();
  }
}

Future<InstructionRecords> instructionRecords() async {
  final records = InstructionRecords();
  await RuntimeSetupStore(records)
      .save(const RuntimeSetup(python: '/trusted/python'));
  records.writes = 0;
  return records;
}

void main() {
  late InstructionRecords records;
  late InstructionHost host;
  late ProjectInstructionController c;
  setUp(() async {
    records = await instructionRecords();
    host = InstructionHost();
    c = ProjectInstructionController(
      root: '/selected',
      setupStore: RuntimeSetupStore(records),
      host: host,
    );
  });
  tearDown(() => c.dispose());
  test(
    'no automatic read or absent-consent dispatch and no application writes',
    () async {
      expect(host.reads, 0);
      await c.read(['AGENTS.md']);
      expect(host.reads, 0);
      expect(records.writes, 0);
      await c.read(['AGENTS.md'], confirm: (_) async => false);
      expect(host.reads, 0);
      await c.read(['AGENTS.md'], confirm: (_) async => true);
      expect(host.reads, 1);
      expect(c.stale, false);
      expect(records.writes, 0);
    },
  );
  test(
    'relative interpreter and unsupported host refuse before consent',
    () async {
      await RuntimeSetupStore(records).save(const RuntimeSetup());
      var confirms = 0;
      await c.read(
        ['AGENTS.md'],
        confirm: (_) async {
          confirms++;
          return true;
        },
      );
      expect(confirms, 0);
      expect(host.reads, 0);
      host.supported = false;
      await c.read(['AGENTS.md'], confirm: (_) async => true);
      expect(host.reads, 0);
    },
  );
  test('confirmed request freezes setup and selected paths', () async {
    final paths = ['AGENTS.md'];
    await c.read(
      paths,
      confirm: (request) async {
        paths.add('README.md');
        await RuntimeSetupStore(records)
            .save(const RuntimeSetup(python: '/changed/python'));
        expect(request.python, '/trusted/python');
        return true;
      },
    );
    expect(host.request!.python, '/trusted/python');
    expect(host.request!.selectedPaths, ['AGENTS.md']);
  });
  test(
    'failure and cancelled refresh retain stale prior findings privately',
    () async {
      await c.read(['AGENTS.md'], confirm: (_) async => true);
      final old = c.findings;
      host.onRead = (_) async => throw StateError('private-sentinel');
      await c.read(['AGENTS.md'], confirm: (_) async => true);
      expect(identical(old, c.findings), true);
      expect(c.stale, true);
      expect(c.error, isNot(contains('private-sentinel')));
      await c.read(['README.md'], confirm: (_) async => false);
      expect(identical(old, c.findings), true);
      expect(c.stale, true);
    },
  );
  test('Stop during confirmation prevents dispatch and waits for dialog settlement', () async {
    final consent = Completer<bool>();
    final entered = Completer<void>();
    final read = c.read(
      ['AGENTS.md'],
      confirm: (_) {
        entered.complete();
        return consent.future;
      },
    );
    await entered.future;
    await c.cancel();
    expect(c.busy, true);
    await c.read(['AGENTS.md'], confirm: (_) async => true);
    expect(host.reads, 0);
    consent.complete(true);
    await read;
    expect(host.reads, 0);
    expect(c.busy, false);
  });
  test('late host result is dropped while cleanup blocks overlap', () async {
    final result = Completer<ProjectInstructionObservation>(),
        entered = Completer<void>(),
        cleanup = Completer<void>();
    host.onRead = (_) {
      entered.complete();
      return result.future;
    };
    host.onCancel = () => cleanup.future;
    final read = c.read(['AGENTS.md'], confirm: (_) async => true);
    await entered.future;
    final stop = c.cancel();
    result.complete(instructionReply(['AGENTS.md']));
    await Future<void>.delayed(Duration.zero);
    expect(c.busy, true);
    expect(c.findings, isNull);
    await c.read(['README.md'], confirm: (_) async => true);
    expect(host.reads, 1);
    cleanup.complete();
    await stop;
    await read;
    expect(c.findings, isNull);
    expect(c.busy, false);
  });
  test(
    'cleanup uncertainty remains sticky and prevents new dispatch',
    () async {
      host.onCancel = () async => throw StateError('private');
      await c.read(['AGENTS.md'], confirm: (_) async => true);
      expect(c.cleanupUncertain, true);
      expect(c.stale, true);
      await c.read(['AGENTS.md'], confirm: (_) async => true);
      expect(host.reads, 1);
    },
  );
  test(
    'disposal during consent prevents dispatch and late publication',
    () async {
      final consent = Completer<bool>(), entered = Completer<void>();
      final read = c.read(
        ['AGENTS.md'],
        confirm: (_) {
          entered.complete();
          return consent.future;
        },
      );
      await entered.future;
      c.dispose();
      consent.complete(true);
      await read;
      expect(host.reads, 0);
      expect(c.findings, isNull);
    },
  );
  test(
    'synchronous busy listener can stop before consent or dispatch',
    () async {
      c.addListener(() {
        if (c.canStop) c.cancel();
      });
      var confirms = 0;
      await c.read(
        ['AGENTS.md'],
        confirm: (_) async {
          confirms++;
          return true;
        },
      );
      expect(confirms, 0);
      expect(host.reads, 0);
    },
  );
  test('wrong returned readset refuses and selection changes mark prior result stale', () async {
    await c.read(['AGENTS.md'], confirm: (_) async => true);
    final old = c.findings;
    c.invalidateSelection();
    expect(c.stale, true);
    host.onRead = (_) async => instructionReply(['README.md']);
    await c.read(['AGENTS.md'], confirm: (_) async => true);
    expect(identical(old, c.findings), true);
    expect(c.stale, true);
  });
}
