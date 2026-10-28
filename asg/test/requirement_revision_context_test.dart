// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/controllers/requirement_check_report_controller.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/views/requirement_check_report_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'requirement_check_report_test.dart' show Records, prepare, project;

void main() {
  test(
    'typed identity matches copied evidence; legacy identity unavailable',
    () async {
      final records = Records();
      final saved = await prepare(records);
      final store = RequirementCheckReportStore(records);
      expect(store.load(project).revisionContext, contains('unavailable'));
      await SourceGenerationStore(records).save(project.id, saved);
      final report = store.load(project);
      final copied = jsonDecode(report.evidenceJson) as Map;
      expect(report.revisionIdentity!.toJson(), copied['revisionIdentity']);
      expect(report.savedInputsCurrent, copied['savedInputsCurrent']);
      expect(report.revisionContext, contains('match current project records'));
      final legacy = saved.toJson();
      legacy['sources'] = {'lib/main.dart': 'a' * 64};
      records.data['studio.generation.v1.${project.id}'] = jsonEncode(legacy);
      expect(store.load(project).revisionContext, contains('unavailable'));
    },
  );

  testWidgets('reload shows stale approval while retaining saved identity', (
    tester,
  ) async {
    final records = Records();
    final saved = await prepare(records);
    await SourceGenerationStore(records).save(project.id, saved);
    final controller = RequirementCheckReportController(
      project,
      RequirementCheckReportStore(records),
    );
    await tester.pumpWidget(
      MaterialApp(home: RequirementCheckReportScreen(controller: controller)),
    );
    expect(
      find.text('Saved inputs and approval match current project records.'),
      findsOneWidget,
    );
    final identity = controller.report!.revisionIdentity!;
    expect(find.text(identity.savedRunSha256!), findsOneWidget);
    final key = records.data.keys.singleWhere(
      (key) => key.startsWith('studio.requirements.'),
    );
    final board = jsonDecode(records.data[key]!) as Map<String, dynamic>;
    (board['requirements'] as List).first['acceptance'] = 'Changed acceptance';
    await RequirementsStore(records).save(
      project.id,
      RequirementsStore(records).load(project.id),
      RequirementsBoard.fromJson(board),
    );
    await tester.tap(find.text('Reload saved evidence'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Saved inputs or approval are stale relative to current project records.',
      ),
      findsOneWidget,
    );
    expect(
      controller.report!.revisionIdentity!.savedRunSha256,
      identity.savedRunSha256,
    );
    await tester.scrollUntilVisible(
      find.text('Acceptance criteria: not verified'),
      200,
    );
    expect(find.text('Acceptance criteria: not verified'), findsOneWidget);
  });

  testWidgets('selectable revision hashes scroll at narrow enlarged text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(320, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final records = Records();
    final saved = await prepare(records);
    await SourceGenerationStore(records).save(project.id, saved);
    final controller = RequirementCheckReportController(
      project,
      RequirementCheckReportStore(records),
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
    await tester.scrollUntilVisible(find.text('Revision context'), 200);
    final hashes = controller.report!.revisionIdentity!;
    for (final hash in [
      hashes.savedRunSha256,
      hashes.sourceSha256,
      hashes.savedInputSha256,
      hashes.approvalSha256,
      hashes.currentInputSha256,
    ]) {
      expect(
        find.byWidgetPredicate(
          (widget) =>
              widget is SelectionArea &&
              widget.child is Text &&
              (widget.child as Text).data == hash,
        ),
        findsWidgets,
      );
    }
    await tester.scrollUntilVisible(
      find.text('Current input SHA-256'),
      250,
      scrollable: find
          .descendant(
            of: find.byType(ListView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.drag(find.byType(ListView), const Offset(0, 100));
    await tester.pumpAndSettle();
    expect(find.text('Current input SHA-256').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
    expect(controller.report!.evidenceJson, isNot(contains('PRIVATE_')));
  });
}
