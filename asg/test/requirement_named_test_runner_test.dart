// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/services/generation_host_native.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/application_store.dart';

import 'dart:async';

import 'package:asg/models/artifact_inspection.dart';
import 'package:asg/models/named_flutter_test_result.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/named_test_session.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/requirement_named_test_runner.dart';
import 'package:flutter_test/flutter_test.dart';

import 'named_check_observation_test.dart' as fixtures;
import 'requirement_check_report_test.dart' show project;

// Filesystem-only probes need the runner preflight on every CI host.
// No command may reach asset preparation or execution in these tests.
class InspectionHost extends NativeGenerationHost {
  InspectionHost({required super.loadAsset});
  @override
  bool get supported => true;
}

class Session implements NamedTestSession {
  @override
  bool supported = true;
  int inspections = 0, calls = 0;
  bool disposed = false, passed = true, skipDispatch = false;
  int? staleAt;
  Completer<void>? gate;
  void Function()? beforeDispatch, afterDispatch;
  @override
  Future<ArtifactInspection> inspectNamedTestInputs(
    GeneratedProject project,
  ) async {
    inspections++;
    return inspections == staleAt
        ? ArtifactInspection.stale
        : ArtifactInspection.matching;
  }

  @override
  Future<NamedFlutterTestResult> runNamedFlutterTest(
    GeneratedProject project,
    FlutterTestTarget target, {
    required Future<void> Function() beforeStart,
  }) async {
    calls++;
    await gate?.future;
    beforeDispatch?.call();
    if (!skipDispatch) await beforeStart();
    afterDispatch?.call();
    return fixtures.result(passed, selected: target);
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

void main() {
  for (final changed in [
    'pubspec.lock',
    '.dart_tool/package_config.json',
    '.dart_tool/package_graph.json',
  ]) {
    test(
      'native runner refuses changed $changed before helper preparation',
      () async {
        final temp = await Directory.systemTemp.createTemp('asg-named-inputs-');
        final directory = Directory(await temp.resolveSymbolicLinks());
        var assets = 0;
        final host = InspectionHost(
          loadAsset: (_) async {
            assets++;
            throw StateError('Unexpected preparation');
          },
        );
        try {
          await Directory('${directory.path}/build/web')
              .create(recursive: true);
          await Directory('${directory.path}/.dart_tool').create();
          await File('${directory.path}/main.dart').writeAsString('source');
          for (final name in [
            'pubspec.lock',
            '.dart_tool/package_config.json',
            '.dart_tool/package_graph.json',
          ]) {
            await File('${directory.path}/$name').writeAsString('metadata');
          }
          await File('${directory.path}/build/web/index.html')
              .writeAsString('output');
          final records = await fixtures.fixture();
          final input = GenerationInput(
            project,
            ApplicationStore(records).load(project).definition,
          );
          await Directory('${directory.path}/assets').create();
          await File('${directory.path}/assets/app.json')
              .writeAsString(input.applicationJson);
          await File('${directory.path}/asg_project.json')
              .writeAsString(input.metadataJson);
          await File('${directory.path}/build/web/main.dart.js')
              .writeAsString('compiled');
          final data = jsonDecode(records.data['studio.generation.v1.p']!);
          data['directory'] = directory.path;
          data['confinementVersion'] = 1;
          data['sources'] = await NativeGenerationHost.fingerprints(
            directory.path,
            source: true,
          );
          data['outputs'] = await NativeGenerationHost.fingerprints(
            '${directory.path}/build/web',
            source: false,
          );
          final saved = GeneratedProject.fromJson(data);
          data['resolution'] = await NativeGenerationHost.resolutionFiles(
            saved,
          );
          records.data['studio.generation.v1.p'] = jsonEncode(data);
          final store = RequirementCheckReportStore(records);
          final selected = store.load(project);
          expect(selected.canRecordManualObservation, isTrue);
          expect(
            await host.inspectNamedTestInputs(selected.savedProject!),
            ArtifactInspection.matching,
          );
          await File('${directory.path}/$changed').writeAsString('changed');
          expect(
            await host.inspectNamedTestInputs(selected.savedProject!),
            ArtifactInspection.unavailable,
          );
          await expectLater(
            RequirementNamedTestRunner(store, createSession: () => host).run(
              project,
              selected,
              selected.results.first.requirement.id,
              'Auto',
              authorized: () => true,
            ),
            throwsStateError,
          );
          expect(assets, 0);
          expect(store.load(project).namedObservations, isEmpty);
        } finally {
          await host.dispose();
          await directory.delete(recursive: true);
        }
      },
    );
  }
  test('overlapping execution refuses; revoked run retains evidence and retry works', () async {
    final records = await fixtures.fixture();
    final data = jsonDecode(records.data['studio.generation.v1.p']!);
    data['confinementVersion'] = 1;
    records.data['studio.generation.v1.p'] = jsonEncode(data);
    final store = RequirementCheckReportStore(records);
    final selected = store.load(project);
    final session = Session()..gate = Completer<void>();
    var allowed = true;
    final runner = RequirementNamedTestRunner(
      store,
      createSession: () => session,
    );
    Future<void> run() => runner.run(
      project,
      selected,
      selected.results.first.requirement.id,
      'Auto',
      authorized: () => allowed,
    );
    final pending = run();
    await Future<void>.delayed(Duration.zero);
    await expectLater(run(), throwsStateError);
    allowed = false;
    final refused = expectLater(pending, throwsStateError);
    session.gate!.complete();
    await refused;
    expect(session.disposed, isTrue);
    expect(store.load(project).namedObservations, isEmpty);
    allowed = true;
    session.gate = null;
    await run();
    expect(store.load(project).namedObservations, hasLength(1));
  });
  for (final passed in [true, false]) {
    test(
      'binds sanitized $passed result to exact saved authored check',
      () async {
        final records = await fixtures.fixture();
        final data = jsonDecode(records.data['studio.generation.v1.p']!);
        data['confinementVersion'] = 1;
        records.data['studio.generation.v1.p'] = jsonEncode(data);
        final store = RequirementCheckReportStore(records);
        final selected = store.load(project);
        final session = Session()..passed = passed;
        await RequirementNamedTestRunner(
          store,
          createSession: () => session,
        ).run(
          project,
          selected,
          selected.results.first.requirement.id,
          'Auto',
          authorized: () => true,
        );
        final current = store.load(project);
        expect(current.namedObservations.single.result.passed, passed);
        expect(
          current.namedObservationCurrent(current.namedObservations.single),
          isTrue,
        );
        expect(session.inspections, 3);
        expect(session.disposed, isTrue);
        expect(current.evidenceJson, isNot(contains('PRIVATE_OUTPUT')));
      },
    );
  }
  for (final failure in [
    'unsupported',
    'unconfined',
    'manual',
    'missing',
    'staleBefore',
    'staleDispatch',
    'staleAfter',
    'changedBeforeDispatch',
    'changedAfterDispatch',
    'revoked',
    'storage',
    'noDispatch',
  ]) {
    test('refuses $failure and retains previous records', () async {
      final records = await fixtures.fixture();
      final data = jsonDecode(records.data['studio.generation.v1.p']!);
      if (failure != 'unconfined') data['confinementVersion'] = 1;
      records.data['studio.generation.v1.p'] = jsonEncode(data);
      final store = RequirementCheckReportStore(records);
      final selected = store.load(project);
      final session = Session();
      var allowed = true;
      switch (failure) {
        case 'unsupported':
          session.supported = false;
        case 'staleBefore':
          session.staleAt = 1;
        case 'staleDispatch':
          session.staleAt = 2;
        case 'staleAfter':
          session.staleAt = 3;
        case 'changedBeforeDispatch':
          session.beforeDispatch = () {
            records.data.remove('studio.generation.v1.p');
          };
        case 'changedAfterDispatch':
          session.afterDispatch = () {
            records.data.remove('studio.generation.v1.p');
          };
        case 'revoked':
          session.afterDispatch = () {
            allowed = false;
          };
        case 'storage':
          records.fail = true;
        case 'noDispatch':
          session.skipDispatch = true;
      }
      final before = Map.of(records.data);
      await expectLater(
        RequirementNamedTestRunner(store, createSession: () => session).run(
          project,
          selected,
          selected.results.first.requirement.id,
          failure == 'manual'
              ? 'Manual'
              : failure == 'missing'
              ? 'Absent'
              : 'Auto',
          authorized: () => allowed,
        ),
        throwsA(anything),
      );
      if (!failure.startsWith('changed')) expect(records.data, before);
      expect(
        session.disposed,
        !['unconfined', 'manual', 'missing'].contains(failure),
      );
      if ([
        'unconfined',
        'manual',
        'missing',
        'unsupported',
        'staleBefore',
      ].contains(failure)) {
        expect(session.calls, 0);
      }
    });
  }
}
