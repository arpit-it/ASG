// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:io';

import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/models/generation_toolchain.dart';
import 'package:asg/services/generation_host.dart';
import 'package:asg/services/generation_toolchain_native.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/views/source_generation_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'source_generation_controller_test.dart'
    show FixtureHost, project, definition;

class InspectionHost extends FixtureHost implements GenerationToolchainSource {
  Completer<GenerationToolchain>? gate;
  int toolInspections = 0;
  String? selectedSdk, selectedPython;
  Object? failure;
  @override
  Future<GenerationToolchain> inspectToolchain(
    String sdk,
    String python,
  ) async {
    toolInspections++;
    selectedSdk = sdk;
    selectedPython = python;
    if (failure != null) throw failure!;
    return gate?.future ??
        const GenerationToolchain(
          'SDK observed',
          'Dart observed',
          'Python observed',
        );
  }
}

void main() {
  group('actual read-only file observations', () {
    late Directory root;
    setUp(
      () async => root = Directory(
        await (await Directory.systemTemp.createTemp('asg tool paths '))
            .resolveSymbolicLinks(),
      ),
    );
    tearDown(() async => root.delete(recursive: true));
    Future<File> executable(String relative) async {
      final file = File('${root.path}/$relative');
      await file.parent.create(recursive: true);
      await file.writeAsString('#!/bin/sh\ntouch "${root.path}/EXECUTED"\n');
      expect((await Process.run('/bin/chmod', ['755', file.path])).exitCode, 0);
      return file;
    }

    test(
      'spaces, SDK Dart, PATH Python and aliases without execution',
      () async {
        await executable('sdk/bin/flutter');
        await executable('sdk/bin/cache/dart-sdk/bin/dart');
        final python = await executable('tools/python3');
        await Link('${root.path}/tools/python').create(python.path);
        final report = await inspectGenerationToolchain(
          '${root.path}/sdk',
          'python',
          searchPath: ':relative:${root.path}/tools',
        );
        for (final value in [report.flutter, report.dart, report.python]) {
          expect(value, contains('executable permission bits observed'));
        }
        expect(await File('${root.path}/EXECUTED').exists(), isFalse);
      },
    );
    test('missing and relative inputs give private guidance', () async {
      final report = await inspectGenerationToolchain(
        '${root.path}/private-missing',
        'relative/python',
        searchPath: '',
      );
      expect(report.flutter, contains('SDK directory unavailable'));
      expect(report.dart, report.flutter);
      expect(report.python, contains('absolute Python'));
      expect('${report.flutter}${report.python}', isNot(contains(root.path)));
    });
    test('nonexecutable and directory entries are not accepted', () async {
      await Directory('${root.path}/sdk/bin/flutter').create(recursive: true);
      final python = File('${root.path}/python');
      await python.writeAsString('not executable');
      await Process.run('/bin/chmod', ['644', python.path]);
      final report = await inspectGenerationToolchain(
        '${root.path}/sdk',
        python.path,
      );
      expect(report.flutter, contains('No regular'));
      expect(report.python, contains('no executable permission'));
      expect(report.dart, contains('unavailable'));
    });
    test(
      'SDK aliases refused, Python lookup bounded without relative search',
      () async {
        await Directory('${root.path}/sdk').create();
        await Link('${root.path}/alias').create('${root.path}/sdk');
        await executable('tools/python3');
        final report = await inspectGenerationToolchain(
          '${root.path}/alias',
          'python3',
          searchPath:
              '${List.filled(64, 'relative').join(':')}:${root.path}/tools',
        );
        expect(report.flutter, contains('real Flutter SDK'));
        expect(report.python, contains('not found'));
        final invalid = await inspectGenerationToolchain(
          'x' * 4097,
          '\u0000',
          searchPath: root.path,
        );
        expect(invalid.python, contains('absolute Python'));
      },
    );
    test(
      'first matching PATH entry cannot be hidden by later executable',
      () async {
        await Directory('${root.path}/first/python3').create(recursive: true);
        await executable('second/python3');
        final report = await inspectGenerationToolchain(
          '',
          'python3',
          searchPath: '${root.path}/first:${root.path}/second',
        );
        expect(report.python, contains('No regular'));
      },
    );
  });

  late InspectionHost host;
  late SourceGenerationController controller;
  late SharedPreferences preferences;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    preferences = await SharedPreferences.getInstance();
    host = InspectionHost();
    controller = SourceGenerationController(
      project: project,
      definition: definition,
      store: SourceGenerationStore(PreferenceRecords(preferences)),
      host: host,
    );
  });
  tearDown(() {
    if (!controller.isDisposed) controller.dispose();
  });
  test('busy exclusion and exact draft, no writes or generation', () async {
    host.gate = Completer();
    final pending = controller.inspectToolchain(
      '/selected sdk',
      '/selected python',
    );
    await controller.inspectToolchain('/other', 'other');
    expect(controller.busy, isTrue);
    expect(host.toolInspections, 1);
    expect(host.selectedSdk, '/selected sdk');
    expect(host.selectedPython, '/selected python');
    expect(
      await controller.generate(
        parent: '/tmp',
        name: 'test_app',
        sdk: '/sdk',
        python: 'python',
        approved: true,
      ),
      isFalse,
    );
    host.gate!.complete(
      const GenerationToolchain('observed', 'observed', 'observed'),
    );
    await pending;
    expect(controller.toolchain!.python, 'observed');
    expect(preferences.getKeys(), isEmpty);
    expect(host.generations, 0);
  });
  test('changed draft and disposal suppress late observations', () async {
    host.gate = Completer();
    final pending = controller.inspectToolchain('/sdk', 'python3');
    controller.invalidateToolchain();
    host.gate!.complete(const GenerationToolchain('stale', 'stale', 'stale'));
    await pending;
    expect(controller.toolchain, isNull);
    host.gate = Completer();
    final disposed = controller.inspectToolchain('/sdk', 'python3');
    controller.dispose();
    host.gate!.complete(const GenerationToolchain('late', 'late', 'late'));
    await disposed;
    expect(controller.toolchain, isNull);
  });
  test('private failure permits retry and invalidation', () async {
    host.failure = StateError('/private/path/token');
    await controller.inspectToolchain('/sdk', 'python3');
    expect(controller.toolchain!.python, contains('retry'));
    expect(controller.toolchain!.python, isNot(contains('private')));
    expect(controller.busy, isFalse);
    host.failure = null;
    await controller.inspectToolchain('/sdk', 'python3');
    expect(controller.toolchain!.python, 'Python observed');
    controller.invalidateToolchain();
    expect(controller.toolchain, isNull);
  });
  testWidgets('320px enlarged Build inspection and edit invalidation', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(2)),
          child: SourceGenerationScreen(controller: controller),
        ),
      ),
    );
    final inspect = find.text('Inspect toolchain paths');
    await tester.scrollUntilVisible(
      inspect,
      250,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(inspect);
    await tester.pumpAndSettle();
    expect(find.text('Python: Python observed'), findsOneWidget);
    final python = find.widgetWithText(
      TextField,
      'Installed Python 3 executable',
    );
    await tester.scrollUntilVisible(
      python,
      -200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.enterText(python, '/changed python');
    await tester.pump();
    expect(controller.toolchain, isNull);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
  });
}
