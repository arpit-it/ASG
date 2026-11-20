// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:asg/controllers/project_inspection_controller.dart';
import 'package:asg/models/project_metadata_observation.dart';
import 'package:asg/models/runtime_setup.dart';
import 'package:asg/services/folder_picker.dart';
import 'package:asg/services/inspected_folder_store.dart';
import 'package:asg/services/project_metadata_host.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/runtime_setup_store.dart';
import 'package:asg/views/project_inspection_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class ImportRecords implements RecordStorage {
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

class ImportSetup extends RuntimeSetupStore {
  ImportSetup() : super(ImportRecords());
  String python = '/trusted/python';
  bool fail = false;
  int loads = 0;
  @override
  RuntimeSetup load() {
    loads++;
    if (fail) throw StateError('private-sentinel');
    return RuntimeSetup(python: python);
  }
}

Future<bool> approve(ProjectMetadataReadRequest request) async => true;
ProjectMetadataObservation importObservation() =>
    ProjectMetadataObservation.parse(
      jsonEncode({
        'version': 1,
        'scope': 'project-metadata-files',
        'status': 'observed',
        'reason': null,
        'manifest_base64': base64Encode(
          utf8.encode(
            'name: controlled_app\nenvironment:\n  sdk: ">=3.0.0 <4.0.0"\ndependencies:\n  flutter:\n    sdk: flutter\n',
          ),
        ),
        'included_runners': ['web'],
        'main_present': true,
        'source_verified': false,
      }),
    );

class ImportHost implements ProjectMetadataHost {
  @override
  bool supported = true;
  final requests = <ProjectMetadataReadRequest>[];
  Future<ProjectMetadataObservation> Function()? read;
  Future<void> Function()? stop;
  int cancels = 0, disposals = 0;
  @override
  Future<ProjectMetadataObservation> inspect(
    ProjectMetadataReadRequest request,
  ) {
    requests.add(request);
    return read?.call() ?? Future.value(importObservation());
  }

  @override
  Future<void> cancel() {
    cancels++;
    return stop?.call() ?? Future.value();
  }

  @override
  Future<void> dispose() async {
    disposals++;
  }
}

class ImportPicker extends FolderPicker {
  Future<String?> Function() select = () async => '/project';
  int calls = 0;
  @override
  bool get supported => true;
  @override
  Future<String?> pick() {
    calls++;
    return select();
  }
}

ProjectInspectionController importController(
  ImportHost host,
  ImportSetup setup, {
  ImportPicker? picker,
}) => ProjectInspectionController(
  picker: picker ?? ImportPicker(),
  host: host,
  setupStore: setup,
);

void main() {
  test('open screen state and absent consent never dispatch helper or settings writes', () async {
    final host = ImportHost(), setup = ImportSetup();
    final c = importController(host, setup);
    expect(setup.loads, 0);
    expect(host.requests, isEmpty);
    await c.chooseFolder();
    expect(host.requests, isEmpty);
    expect(c.error, contains('explicit confirmation'));
    expect((setup.records as ImportRecords).writes, 0);
    c.dispose();
  });
  test('bad settings refuse before consent or helper', () async {
    final host = ImportHost(), setup = ImportSetup();
    final c = importController(host, setup);
    var confirmations = 0;
    for (final python in ['python3', '', '/bad\npython']) {
      setup.python = python;
      await c.chooseFolder(
        confirm: (_) async {
          confirmations++;
          return true;
        },
      );
    }
    setup.fail = true;
    await c.chooseFolder(
      confirm: (_) async {
        confirmations++;
        return true;
      },
    );
    expect(confirmations, 0);
    expect(host.requests, isEmpty);
    expect(c.error, isNot(contains('private-sentinel')));
    c.dispose();
  });
  test('confirmation freezes interpreter and cancelled confirmation never dispatches', () async {
    final host = ImportHost(), setup = ImportSetup();
    final c = importController(host, setup);
    await c.chooseFolder(confirm: (_) async => false);
    expect(host.requests, isEmpty);
    final consent = Completer<bool>();
    final work = c.chooseFolder(
      confirm: (request) {
        expect(request.python, '/trusted/python');
        setup.python = '/different/python';
        return consent.future;
      },
    );
    await Future<void>.delayed(Duration.zero);
    expect(c.confirming, isTrue);
    expect(host.requests, isEmpty);
    consent.complete(true);
    await work;
    expect(host.requests.single.python, '/trusted/python');
    expect(c.findings!.packageName, 'controlled_app');
    c.dispose();
  });
  test(
    'synchronous busy listener Stop or disposal prevents dispatch',
    () async {
      for (final dispose in [false, true]) {
        final host = ImportHost(),
            setup = ImportSetup(),
            picker = ImportPicker();
        final c = importController(host, setup, picker: picker);
        c.addListener(() {
          if (c.busy) {
            if (dispose) {
              c.dispose();
            } else {
              unawaited(c.cancel());
            }
          }
        });
        await c.chooseFolder(confirm: approve);
        expect(host.requests, isEmpty);
        expect(picker.calls, 0);
        c.dispose();
      }
    },
  );
  test('stopped late success waits cleanup and cannot publish', () async {
    final host = ImportHost(),
        c = importController(ImportHost(), ImportSetup());
    c.dispose();
    final controller = importController(host, ImportSetup());
    final read = Completer<ProjectMetadataObservation>(),
        cleanup = Completer<void>();
    host.read = () => read.future;
    host.stop = () => cleanup.future;
    final work = controller.chooseFolder(confirm: approve);
    await Future<void>.delayed(Duration.zero);
    final stop = controller.cancel();
    read.complete(importObservation());
    await Future<void>.delayed(Duration.zero);
    expect(controller.busy, isTrue);
    expect(controller.findings, isNull);
    cleanup.complete();
    await stop;
    await work;
    expect(controller.busy, isFalse);
    expect(host.cancels, 1);
    controller.dispose();
  });
  test(
    'failed read retains stale findings and private cleanup guidance',
    () async {
      final host = ImportHost();
      final c = importController(host, ImportSetup());
      await c.chooseFolder(confirm: approve);
      final prior = c.findings;
      host.read = () => Future.error(StateError('private-sentinel'));
      host.stop = () => Future.error(StateError('private-sentinel'));
      await c.chooseFolder(confirm: approve);
      expect(c.findings, same(prior));
      expect(c.stale, isTrue);
      expect(c.cleanupUncertain, isTrue);
      expect(c.canOpenWorkspace, isFalse);
      expect(c.error, isNot(contains('private-sentinel')));
      final count = host.requests.length;
      await c.chooseFolder(confirm: approve);
      expect(host.requests.length, count);
      c.dispose();
    },
  );
  test(
    'Stop during picker blocks a later selection and overlapping chooser',
    () async {
      final host = ImportHost(), picker = ImportPicker();
      final picked = Completer<String?>();
      picker.select = () => picked.future;
      final c = importController(host, ImportSetup(), picker: picker);
      final work = c.chooseFolder(confirm: approve);
      await c.cancel();
      expect(c.busy, isTrue);
      await c.chooseFolder(confirm: approve);
      expect(picker.calls, 1);
      picked.complete('/late');
      await work;
      expect(host.requests, isEmpty);
      expect(c.busy, isFalse);
      c.dispose();
    },
  );
  test('Stop during confirmation retains stale findings and prevents late dispatch', () async {
    final host = ImportHost();
    final c = importController(host, ImportSetup());
    await c.chooseFolder(confirm: approve);
    final prior = c.findings;
    final consent = Completer<bool>();
    final work = c.chooseFolder(confirm: (_) => consent.future);
    await Future<void>.delayed(Duration.zero);
    await c.cancel();
    expect(c.busy, isTrue);
    expect(c.stale, isTrue);
    consent.complete(true);
    await work;
    expect(host.requests, hasLength(1));
    expect(c.findings, same(prior));
    c.dispose();
  });
  test(
    'workspace result cannot escape disposal on final busy notification',
    () async {
      final host = ImportHost(), records = ImportRecords();
      final store = InspectedFolderStore(records);
      final c = ProjectInspectionController(
        picker: ImportPicker(),
        host: host,
        setupStore: ImportSetup(),
        store: store,
      );
      await c.chooseFolder(confirm: approve);
      await c.saveFolder();
      c.addListener(() {
        if (!c.busy) c.dispose();
      });
      expect(await c.openWorkspace(confirm: approve), isNull);
      expect(c.isDisposed, isTrue);
      expect(store.load(), ['/project']);
    },
  );
  testWidgets('changed controller invalidates pending dialog consent', (
    tester,
  ) async {
    final oldHost = ImportHost(), newHost = ImportHost();
    final old = importController(oldHost, ImportSetup());
    final next = importController(
      newHost,
      ImportSetup(),
      picker: ImportPicker()..select = () async => '/different',
    );
    Widget screen(ProjectInspectionController c) =>
        MaterialApp(home: ProjectInspectionScreen(controller: c));
    await tester.pumpWidget(screen(old));
    await tester.tap(find.text('Choose Flutter folder'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(screen(next));
    await tester.pump();
    expect(old.isDisposed, isTrue);
    await tester.tap(find.text('Inspect metadata'));
    await tester.pumpAndSettle();
    expect(oldHost.requests, isEmpty);
    expect(newHost.requests, isEmpty);
    await tester.tap(find.text('Choose Flutter folder'));
    await tester.pumpAndSettle();
    expect(find.text('Folder: /different'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
  });
  testWidgets(
    'narrow enlarged confirmation can cancel without overflow or launch',
    (tester) async {
      tester.view.physicalSize = const Size(320, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final host = ImportHost();
      final c = importController(host, ImportSetup());
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: const TextScaler.linear(2)),
            child: child!,
          ),
          home: ProjectInspectionScreen(controller: c),
        ),
      );
      await tester.scrollUntilVisible(
        find.text('Choose Flutter folder'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Choose Flutter folder'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(host.requests, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'view needs explicit dialog confirmation and preserves previous reading on refusal',
    (tester) async {
      final host = ImportHost(), setup = ImportSetup();
      final c = importController(host, setup);
      await tester.pumpWidget(
        MaterialApp(home: ProjectInspectionScreen(controller: c)),
      );
      expect(setup.loads, 0);
      expect(host.requests, isEmpty);
      await tester.tap(find.text('Choose Flutter folder'));
      await tester.pumpAndSettle();
      expect(find.text('Folder: /project'), findsOneWidget);
      expect(
        find.text('Existing interpreter: /trusted/python'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(host.requests, isEmpty);
      await tester.tap(find.text('Choose Flutter folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inspect metadata'));
      await tester.pumpAndSettle();
      expect(host.requests, hasLength(1));
      expect(find.text('Package: controlled_app'), findsOneWidget);
      host.read = () => Future.error(StateError('private-sentinel'));
      await tester.tap(find.text('Choose Flutter folder'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Inspect metadata'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Previous findings retained'), findsOneWidget);
      expect(find.textContaining('private-sentinel'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
