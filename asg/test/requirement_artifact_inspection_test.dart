// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'package:asg/controllers/requirement_check_report_controller.dart';
import 'package:asg/models/artifact_inspection.dart';
import 'package:asg/models/requirement_check_report.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/generation_host_stub.dart';
import 'package:asg/services/requirement_artifact_inspector.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/views/requirement_check_report_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'requirement_check_report_test.dart' show Records, prepare, project;

class Inspector implements ArtifactInspector {
  int calls = 0;
  GeneratedProject? selected;
  Completer<ArtifactInspection>? gate;
  ArtifactInspection outcome = ArtifactInspection.matching;
  bool fail = false;
  @override
  Future<ArtifactInspection> inspectArtifacts(GeneratedProject project) async {
    calls++;
    selected = project;
    if (fail) throw StateError('PRIVATE_PATH_AND_LOG');
    return gate?.future ?? outcome;
  }
}

class OwnedHost extends UnsupportedGenerationHost implements ArtifactInspector {
  bool closed = false, fail = false;
  @override
  Future<ArtifactInspection> inspectArtifacts(GeneratedProject project) async {
    if (fail) throw StateError('PRIVATE_PATH');
    return ArtifactInspection.matching;
  }

  @override
  Future<void> dispose() async {
    closed = true;
  }
}

void main() {
  test(
    'all artifact outcomes remain read-only and separate from acceptance',
    () async {
      final records = Records();
      final saved = await prepare(records);
      await SourceGenerationStore(records).save('p', saved);
      final before = Map.of(records.data);
      final inspector = Inspector();
      final observed = DateTime.parse('2026-10-28T03:00:00+05:30');
      final controller = RequirementCheckReportController(
        project,
        RequirementCheckReportStore(records),
        inspector: inspector,
        clock: () => observed,
      );
      controller.load();
      expect(inspector.calls, 0);
      expect(
        (jsonDecode(controller.evidenceJson!) as Map)['artifactInspection'],
        isNull,
      );
      final savedJson = controller.report!.evidenceJson;
      for (final outcome in ArtifactInspection.values) {
        inspector.outcome = outcome;
        await controller.inspectArtifacts();
        expect(controller.inspection, outcome);
        final exported = jsonDecode(controller.evidenceJson!) as Map;
        final observation = exported['artifactInspection'] as Map;
        expect(observation['outcome'], outcome.name);
        expect(observation['observedAt'], '2026-10-27T21:30:00.000Z');
        expect(controller.inspectedAt, observed.toUtc());
        expect(
          observation['savedEvidenceSha256'],
          sha256.convert(utf8.encode(savedJson)).toString(),
        );
        expect(exported['savedEvidence'], jsonDecode(savedJson));
        expect(
          observation['scope'],
          contains('not a semantic acceptance verdict'),
        );
        expect(controller.report!.evidenceJson, savedJson);
        expect(controller.evidenceJson, isNot(contains('PRIVATE_')));
        expect(
          controller.evidenceJson,
          isNot(contains(controller.report!.snapshotFingerprint)),
        );

        expect(controller.inspecting, isFalse);
        expect(
          controller.report!.results.single.state,
          RequirementCheckState.mappedChecksPassed,
        );
        expect(
          RequirementCheckResult.acceptanceStatus,
          contains('not verified'),
        );
        expect(inspector.selected!.toJson(), saved.toJson());
        expect(records.data, before);
      }
      inspector.fail = true;
      await controller.inspectArtifacts();
      expect(controller.inspection, ArtifactInspection.unavailable);
      expect(controller.error, isNull);
      controller.load();
      expect(controller.inspection, isNull);
      expect(controller.inspectedAt, isNull);
      expect(
        (jsonDecode(controller.evidenceJson!) as Map)['artifactInspection'],
        isNull,
      );
      controller.dispose();
    },
  );
  test('changed saved pointer discards delayed result despite identical fingerprints', () async {
    final records = Records();
    final saved = await prepare(records);
    final store = SourceGenerationStore(records);
    await store.save('p', saved);
    final inspector = Inspector()..gate = Completer<ArtifactInspection>();
    final controller = RequirementCheckReportController(
      project,
      RequirementCheckReportStore(records),
      inspector: inspector,
    );
    final pending = controller.inspectArtifacts();
    expect(controller.inspecting, isTrue);
    await controller.inspectArtifacts();
    expect(inspector.calls, 1);
    final changed = GeneratedProject.fromJson(
      saved.toJson()..['directory'] = 'OTHER_PRIVATE_DIRECTORY',
    );
    await store.save('p', changed);
    inspector.gate!.complete(ArtifactInspection.matching);
    await pending;
    expect(controller.inspection, isNull);
    expect(controller.inspectionNotice, contains('changed during inspection'));
    expect(controller.inspectedAt, isNull);
    expect(
      (jsonDecode(controller.evidenceJson!) as Map)['artifactInspection'],
      isNull,
    );
    expect(controller.report!.savedProject!.directory, changed.directory);
    expect(controller.report!.evidenceJson, isNot(contains('PRIVATE')));
    controller.dispose();
  });
  test('reload, corruption and disposal reject delayed success', () async {
    for (final action in ['reload', 'corrupt', 'dispose']) {
      final records = Records();
      final saved = await prepare(records);
      await SourceGenerationStore(records).save('p', saved);
      final inspector = Inspector()..gate = Completer<ArtifactInspection>();
      final controller = RequirementCheckReportController(
        project,
        RequirementCheckReportStore(records),
        inspector: inspector,
      );
      var notifications = 0;
      controller.addListener(() => notifications++);
      final pending = controller.inspectArtifacts();
      switch (action) {
        case 'reload':
          controller.load();
        case 'corrupt':
          records.data['studio.generation.v1.p'] = 'PRIVATE_CORRUPT';
        case 'dispose':
          controller.dispose();
      }
      final count = notifications;
      inspector.gate!.complete(ArtifactInspection.matching);
      await pending;
      expect(controller.inspection, isNull);
      if (action == 'corrupt') {
        expect(controller.report, isNull);
        expect(controller.evidenceJson, isNull);
        expect(controller.error, isNot(contains('PRIVATE')));
      }
      if (action == 'dispose') {
        expect(notifications, count);
      } else {
        expect(controller.inspecting, isFalse);
        controller.dispose();
      }
    }
  });
  test('missing saved evidence never dispatches inspection', () async {
    final records = Records();
    await prepare(records);
    final inspector = Inspector();
    final controller = RequirementCheckReportController(
      project,
      RequirementCheckReportStore(records),
      inspector: inspector,
    );
    await controller.inspectArtifacts();
    expect(inspector.calls, 0);
    expect(controller.inspection, isNull);
    controller.dispose();
  });
  test('adapter disposes sessions on success/failure and reports unsupported hosts', () async {
    final saved = await prepare(Records());
    for (final fail in [false, true]) {
      final host = OwnedHost()..fail = fail;
      final service = RequirementArtifactInspector(createHost: () => host);
      if (fail) {
        await expectLater(service.inspectArtifacts(saved), throwsStateError);
      } else {
        expect(
          await service.inspectArtifacts(saved),
          ArtifactInspection.matching,
        );
      }
      expect(host.closed, isTrue);
    }
    expect(
      await RequirementArtifactInspector(
        createHost: UnsupportedGenerationHost.new,
      ).inspectArtifacts(saved),
      ArtifactInspection.unavailable,
    );
  });
  testWidgets(
    'explicit inspection shows progress and missing artifacts at narrow double text',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final records = Records();
      final saved = await prepare(records);
      await SourceGenerationStore(records).save('p', saved);
      final inspector = Inspector()..gate = Completer<ArtifactInspection>();
      final controller = RequirementCheckReportController(
        project,
        RequirementCheckReportStore(records),
        inspector: inspector,
      );
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(2)),
            child: child!,
          ),
          home: RequirementCheckReportScreen(controller: controller),
        ),
      );
      expect(inspector.calls, 0);
      await tester.scrollUntilVisible(
        find.text('Inspect current artifacts'),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Inspect current artifacts'));
      await tester.pump();
      expect(find.text('Inspecting current artifacts…'), findsOneWidget);
      expect(find.byType(LinearProgressIndicator), findsOneWidget);
      inspector.gate!.complete(ArtifactInspection.missing);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(ArtifactInspection.missing.label),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.scrollUntilVisible(
        find.textContaining('Observed at '),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.textContaining('(UTC); files may change afterward.'),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Exact saved revision and results'),
        300,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.tap(find.text('Exact saved revision and results'));
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(controller.evidenceJson!),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.textContaining('"artifactInspection"'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text(RequirementCheckResult.acceptanceStatus),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text(RequirementCheckResult.acceptanceStatus),
        findsOneWidget,
      );
      await tester.scrollUntilVisible(
        find.text('Reload saved evidence'),
        -150,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.ensureVisible(find.text('Reload saved evidence'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Reload saved evidence'));
      await tester.pump();
      expect(find.text(ArtifactInspection.missing.label), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
