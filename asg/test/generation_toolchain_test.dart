// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:io';

import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/models/generation_toolchain.dart';
import 'package:asg/services/generation_host.dart';
import 'package:asg/services/generation_host_native.dart';
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
  bool generationSupported = true;
  @override
  bool get supported => generationSupported;
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
    test('native host observes files without enabling generation', () async {
      await executable('sdk/bin/flutter');
      await executable('sdk/bin/cache/dart-sdk/bin/dart');
      final python = await executable('tools/python3');
      final native = NativeGenerationHost();
      try {
        final report = await native.inspectToolchain(
          '${root.path}/sdk',
          python.path,
        );
        for (final value in [report.flutter, report.dart, report.python]) {
          expect(value, contains('executable permission bits observed'));
        }
        expect(await File('${root.path}/EXECUTED').exists(), isFalse);
        expect(native.supported, Platform.isMacOS);
        expect(native.capabilities.starterCreation, Platform.isMacOS);
        expect(native.capabilities.starterVerification, Platform.isMacOS);
        expect(native.capabilities.candidateConfinement, Platform.isMacOS);
        expect(native.capabilities.webPreview, Platform.isMacOS);
      } finally {
        await native.dispose();
      }
      await expectLater(native.inspectToolchain('', ''), throwsStateError);
    });
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
    test('incomplete SDK identifies the missing bundled tool', () async {
      final flutter = await executable('sdk/bin/flutter');
      final sdk = '${root.path}/sdk';
      final report = await inspectGenerationToolchain(sdk, '');
      expect(report.flutter, contains('executable permission bits observed'));
      expect(report.dart, contains('bin/cache/dart-sdk/bin/dart'));
      expect(report.dart, isNot(contains(sdk)));

      await flutter.delete();
      await executable('sdk/bin/cache/dart-sdk/bin/dart');
      final retry = await inspectGenerationToolchain(sdk, '');
      expect(retry.flutter, contains('bin/flutter'));
      expect(retry.flutter, isNot(contains(sdk)));
      expect(retry.dart, contains('executable permission bits observed'));
      expect(await File('${root.path}/EXECUTED').exists(), isFalse);
    });
    test('nonexecutable and directory entries are not accepted', () async {
      await Directory('${root.path}/sdk/bin/flutter').create(recursive: true);
      final dart = File('${root.path}/sdk/bin/cache/dart-sdk/bin/dart');
      await dart.create(recursive: true);
      await Process.run('/bin/chmod', ['644', dart.path]);
      final python = File('${root.path}/python');
      await python.writeAsString('not executable');
      await Process.run('/bin/chmod', ['644', python.path]);
      final report = await inspectGenerationToolchain(
        '${root.path}/sdk',
        python.path,
      );
      expect(report.flutter, contains('No regular'));
      expect(report.python, contains('no executable permission'));
      expect(report.flutter, contains('bin/flutter'));
      expect(report.dart, contains('bin/cache/dart-sdk/bin/dart'));
      expect(report.dart, contains('no executable permission'));
      expect('${report.flutter} ${report.dart}', isNot(contains(root.path)));
    });
    test(
      'SDK file, linked SDK, and missing tools have distinct guidance',
      () async {
        final sdkFile = await executable('sdk-file');
        final sdk = await Directory('${root.path}/sdk').create();
        final alias = await Link('${root.path}/alias').create(sdk.path);
        for (final entry in {
          sdkFile.path: 'not a directory',
          alias.path: 'real Flutter SDK',
          sdk.path: 'File unavailable',
        }.entries) {
          final report = await inspectGenerationToolchain(
            entry.key,
            sdkFile.path,
          );
          expect(report.flutter, contains(entry.value));
          expect(report.dart, contains(entry.value));
          expect(
            '${report.flutter} ${report.dart}',
            isNot(contains(root.path)),
          );
        }
        final invalid = await inspectGenerationToolchain('x' * 4097, '\u0000');
        expect(invalid.python, contains('absolute Python'));
      },
    );
    test(
      'PATH caps raw entries and reports which folders were eligible',
      () async {
        await executable('tools/python3');
        final tools = '${root.path}/tools';
        final missing = '${root.path}/missing';
        final relative = List.filled(62, 'relative').join(':');
        final observed = await inspectGenerationToolchain(
          '',
          'python3',
          searchPath: '$missing:$relative:$tools',
        );
        expect(
          observed.python,
          contains('executable permission bits observed'),
        );
        final bounded = await inspectGenerationToolchain(
          '',
          'python3',
          searchPath: '$missing:$relative::$tools',
        );
        expect(
          bounded.python,
          contains('eligible directories among the first 64 PATH entries'),
        );
        final ineligible = await inspectGenerationToolchain(
          '',
          'python3',
          searchPath: 'relative:$relative::$tools',
        );
        expect(
          ineligible.python,
          contains('no eligible absolute directory paths'),
        );
        final empty = await inspectGenerationToolchain(
          '',
          'python3',
          searchPath: '',
        );
        expect(empty.python, contains('PATH is unavailable or empty'));
        expect(
          '${bounded.python} ${ineligible.python}',
          isNot(contains(root.path)),
        );
        expect(await File('${root.path}/EXECUTED').exists(), isFalse);
      },
    );
    test(
      'oversized PATH skips lookup but not an absolute Python selection',
      () async {
        final python = await executable('tools/python3');
        final prefix = '${root.path}/tools:';
        final withinLimit = prefix + 'x' * (65536 - prefix.length);
        final overLimit = '${withinLimit}x';
        final observed = await inspectGenerationToolchain(
          '',
          'python3',
          searchPath: withinLimit,
        );
        expect(
          observed.python,
          contains('executable permission bits observed'),
        );
        final skipped = await inspectGenerationToolchain(
          '',
          'python3',
          searchPath: overLimit,
        );
        expect(skipped.python, contains('PATH exceeds the inspection limit'));
        expect(skipped.python, contains('absolute Python executable'));
        expect(skipped.python, isNot(contains(root.path)));
        final absolute = await inspectGenerationToolchain(
          '',
          python.path,
          searchPath: overLimit,
        );
        expect(
          absolute.python,
          contains('executable permission bits observed'),
        );
        expect(await File('${root.path}/EXECUTED').exists(), isFalse);
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
  test('unsupported generation does not block inspection', () async {
    host.generationSupported = false;
    expect(controller.available, isFalse);
    await controller.inspectToolchain('/selected sdk', '/selected python');
    expect(controller.toolchain!.python, 'Python observed');
    expect(host.toolInspections, 1);
    expect(controller.available, isFalse);
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
    expect(host.generations, 0);
    expect(preferences.getKeys(), isEmpty);
  });
  testWidgets('unsupported host can enter and inspect paths', (tester) async {
    host.generationSupported = false;
    await tester.pumpWidget(
      MaterialApp(home: SourceGenerationScreen(controller: controller)),
    );
    for (final entry in {
      'Installed Flutter SDK directory': '/selected sdk',
      'Installed Python 3 executable': '/selected python',
    }.entries) {
      final input = find.widgetWithText(TextField, entry.key);
      await tester.scrollUntilVisible(
        input,
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.enterText(input, entry.value);
    }
    final inspect = find.text('Inspect toolchain paths');
    await tester.scrollUntilVisible(
      inspect,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(inspect);
    await tester.pumpAndSettle();
    expect(find.text('Python: Python observed'), findsOneWidget);
    expect(host.selectedSdk, '/selected sdk');
    expect(host.selectedPython, '/selected python');
    expect(controller.available, isFalse);
    expect(host.generations, 0);
    expect(preferences.getKeys(), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
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
