// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/project_source_controller.dart';
import 'package:asg/models/project_source_observation.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/models/project_inspection.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/project_source_host.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

class SourceRecords implements RecordStorage {
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

ProjectSourceObservation sourceReply(List<String> paths) =>
    ProjectSourceObservation.fromJson(
      jsonEncode({
        'version': 1,
        'scope': 'project-source-files',
        'status': 'observed',
        'reason': null,
        'selected_paths': paths,
        'source_verified': false,
        'files': [
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

class SourceHost implements ProjectSourceHost {
  @override
  bool supported = true;
  int reads = 0, cancels = 0, disposals = 0;
  ProjectSourceReadRequest? request;
  Future<ProjectSourceObservation> Function(ProjectSourceReadRequest)? onRead;
  Future<void> Function()? onCancel;
  @override
  Future<ProjectSourceObservation> inspect(
    ProjectSourceReadRequest value,
  ) async {
    reads++;
    request = value;
    return onRead == null
        ? sourceReply(value.selectedPaths)
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

Future<SourceRecords> sourceRecords() async {
  final records = SourceRecords();
  await RuntimeSetupStore(records)
      .save(const RuntimeSetup(python: '/trusted/python'));
  records.writes = 0;
  return records;
}

void main() {
  late SourceRecords records;
  late SourceHost host;
  late ProjectSourceController c;
  setUp(() async {
    records = await sourceRecords();
    host = SourceHost();
    c = ProjectSourceController(
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
      await c.read(['lib/main.dart']);
      expect(host.reads, 0);
      expect(records.writes, 0);
      await c.read(['lib/main.dart'], confirm: (_) async => false);
      expect(host.reads, 0);
      await c.read(['lib/main.dart'], confirm: (_) async => true);
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
        ['lib/main.dart'],
        confirm: (_) async {
          confirms++;
          return true;
        },
      );
      expect(confirms, 0);
      expect(host.reads, 0);
      host.supported = false;
      await c.read(['lib/main.dart'], confirm: (_) async => true);
      expect(host.reads, 0);
    },
  );
  test('confirmed request freezes setup and selected paths', () async {
    final paths = ['lib/main.dart'];
    await c.read(
      paths,
      confirm: (request) async {
        paths.add('test/other.dart');
        expect(request.python, '/trusted/python');
        return true;
      },
    );
    expect(host.request!.python, '/trusted/python');
    expect(host.request!.selectedPaths, ['lib/main.dart']);
  });
  test(
    'failure and cancelled refresh retain stale prior findings privately',
    () async {
      await c.read(['lib/main.dart'], confirm: (_) async => true);
      final old = c.findings;
      host.onRead = (_) async => throw StateError('private-sentinel');
      await c.read(['lib/main.dart'], confirm: (_) async => true);
      expect(identical(old, c.findings), true);
      expect(c.stale, true);
      expect(c.error, isNot(contains('private-sentinel')));
      await c.read(['test/other.dart'], confirm: (_) async => false);
      expect(identical(old, c.findings), true);
      expect(c.stale, true);
    },
  );
  test('Stop during confirmation prevents dispatch and waits for dialog settlement', () async {
    final consent = Completer<bool>();
    final entered = Completer<void>();
    final read = c.read(
      ['lib/main.dart'],
      confirm: (_) {
        entered.complete();
        return consent.future;
      },
    );
    await entered.future;
    await c.cancel();
    expect(c.busy, true);
    await c.read(['lib/main.dart'], confirm: (_) async => true);
    expect(host.reads, 0);
    consent.complete(true);
    await read;
    expect(host.reads, 0);
    expect(c.busy, false);
  });
  test('late host result is dropped while cleanup blocks overlap', () async {
    final result = Completer<ProjectSourceObservation>(),
        entered = Completer<void>(),
        cleanup = Completer<void>();
    host.onRead = (_) {
      entered.complete();
      return result.future;
    };
    host.onCancel = () => cleanup.future;
    final read = c.read(['lib/main.dart'], confirm: (_) async => true);
    await entered.future;
    final stop = c.cancel();
    result.complete(sourceReply(['lib/main.dart']));
    await Future<void>.delayed(Duration.zero);
    expect(c.busy, true);
    expect(c.findings, isNull);
    await c.read(['test/other.dart'], confirm: (_) async => true);
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
      await c.read(['lib/main.dart'], confirm: (_) async => true);
      expect(c.cleanupUncertain, true);
      expect(c.stale, true);
      await c.read(['lib/main.dart'], confirm: (_) async => true);
      expect(host.reads, 1);
    },
  );
  test(
    'disposal during consent prevents dispatch and late publication',
    () async {
      final consent = Completer<bool>(), entered = Completer<void>();
      final read = c.read(
        ['lib/main.dart'],
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
        ['lib/main.dart'],
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
    await c.read(['lib/main.dart'], confirm: (_) async => true);
    final old = c.findings;
    c.invalidateSelection();
    expect(c.stale, true);
    host.onRead = (_) async => sourceReply(['test/other.dart']);
    await c.read(['lib/main.dart'], confirm: (_) async => true);
    expect(identical(old, c.findings), true);
    expect(c.stale, true);
  });
  test('changed interpreter while consent is open prevents dispatch', () async {
    await c.read(
      ['lib/main.dart'],
      confirm: (_) async {
        await RuntimeSetupStore(records)
            .save(const RuntimeSetup(python: '/changed/python'));
        return true;
      },
    );
    expect(host.reads, 0);
    expect(c.error, isNotNull);
  });
  test('source advisory requires saved reference and fresh capture; no preparation writes', () async {
    final inspection = ProjectInspection(
      root: '/selected',
      packageName: 'fixture',
      dartSdk: '^3.0.0',
      runners: ['web'],
    );
    expect(c.prepareAdvisory(inspection), isNull);
    await c.read(['lib/main.dart'], confirm: (_) async => true);
    expect(c.prepareAdvisory(inspection), isNull);
    await InspectedFolderStore(records).save('/selected');
    final writes = records.writes;
    final context = c.prepareAdvisory(inspection)!;
    expect(context.files.single.path, 'lib/main.dart');
    expect(records.writes, writes);
    c.invalidateSelection();
    expect(c.prepareAdvisory(inspection), isNull);
    expect(c.findings, isNotNull);
  });
  test(
    'wrong metadata root and corrupt requirements never prepare source context',
    () async {
      await InspectedFolderStore(records).save('/selected');
      await c.read(['lib/main.dart'], confirm: (_) async => true);
      final wrong = ProjectInspection(
        root: '/other',
        packageName: 'fixture',
        dartSdk: '^3.0.0',
        runners: ['web'],
      );
      expect(c.prepareAdvisory(wrong), isNull);
      records.values[RequirementsStore.key(
            InspectedFolderStore.workspaceId('/selected'),
          )] =
          'private-invalid';
      final right = ProjectInspection(
        root: '/selected',
        packageName: 'fixture',
        dartSdk: '^3.0.0',
        runners: ['web'],
      );
      expect(c.prepareAdvisory(right), isNull);
      expect(c.error, isNot(contains('private-invalid')));
      c.dispose();
      expect(c.prepareAdvisory(right), isNull);
    },
  );
}
