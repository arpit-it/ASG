// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/build_plan.dart';
import 'package:asg/models/build_task.dart';
import 'package:asg/models/plan_approval.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/views/board_verification_progress.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'board_mapped_build_plan_test.dart';

GeneratedProject snapshot({bool shared = true}) => GeneratedProject(
  directory: '/project',
  sdk: '/sdk',
  python: 'python3',
  sources: {'main.dart': '0' * 64},
  tasks: BuildPlan.parse(
    boardContent(shared ? sharedContract() : boardContract()),
    board: shared ? sharedBoard() : mappedBoard(),
  ).tasks,
  approval: PlanApproval(
    messageIndex: 1,
    content: 'Saved plan',
    context: 'Saved context',
    approved: true,
    recordedAt: DateTime.utc(2026),
  ),
);

List<GenerationStep> steps(int count, {bool failLast = false}) => [
  for (final operation in ['resolve', 'test', 'analyze', 'build'].take(count))
    GenerationStep(
      operation: operation,
      exitCode:
          failLast &&
              operation == ['resolve', 'test', 'analyze', 'build'][count - 1]
          ? 1
          : 0,
      output: 'Result',
    ),
];

void main() {
  test(
    'shared task summaries use actual outcomes through reopen and retry',
    () {
      final base = snapshot();
      void check(
        GeneratedProject result,
        BuildTaskStatus status,
        int passed, {
        bool active = false,
      }) {
        final restored = GeneratedProject.fromJson(result.toJson());
        final summaries = restored.boardVerification(active: active);
        expect(summaries, hasLength(1));
        expect(summaries.single.boardTaskId, 'Tstarter');
        expect(summaries.single.total, 4);
        expect(summaries.single.passed, passed);
        expect(summaries.single.status, status);
        expect(() => summaries.clear(), throwsUnsupportedError);
      }

      check(base, BuildTaskStatus.pending, 0);
      final partial = base.copy(
        phase: SourceGenerationPhase.verifying,
        steps: steps(2),
      );
      check(partial, BuildTaskStatus.running, 2, active: true);
      check(partial, BuildTaskStatus.interrupted, 2);
      check(
        base.copy(
          phase: SourceGenerationPhase.failed,
          steps: steps(2, failLast: true),
        ),
        BuildTaskStatus.failed,
        1,
      );
      check(
        base.copy(
          phase: SourceGenerationPhase.failed,
          steps: steps(2),
          failedOperation: 'analyze',
        ),
        BuildTaskStatus.failed,
        2,
      );
      check(
        base.copy(phase: SourceGenerationPhase.failed, steps: steps(2)),
        BuildTaskStatus.blocked,
        2,
      );
      // Fresh retry clears previous failure; no automatic board completion.
      check(
        base.copy(phase: SourceGenerationPhase.verifying),
        BuildTaskStatus.running,
        0,
        active: true,
      );
      check(
        base.copy(
          phase: SourceGenerationPhase.ready,
          steps: steps(4),
          outputs: {'index.html': '1' * 64, 'main.dart.js': '2' * 64},
        ),
        BuildTaskStatus.passed,
        4,
      );
    },
  );

  test(
    'distinct mappings retain execution order and individual failure identity',
    () {
      final base = snapshot(shared: false);
      final result = GeneratedProject.fromJson(
        base
            .copy(
              phase: SourceGenerationPhase.failed,
              steps: steps(2, failLast: true),
            )
            .toJson(),
      );
      final summaries = result.boardVerification(active: false);
      expect(summaries.map((s) => s.boardTaskId), [
        'Tresolve',
        'Ttest',
        'Tanalyze',
        'Tbuild',
      ]);
      expect(summaries.map((s) => s.status), [
        BuildTaskStatus.passed,
        BuildTaskStatus.failed,
        BuildTaskStatus.blocked,
        BuildTaskStatus.blocked,
      ]);
      expect(summaries.map((s) => s.passed), [1, 0, 0, 0]);
      expect(summaries.every((s) => s.total == 1), isTrue);
      final legacy = GeneratedProject.fromJson(
        base.toJson()
          ..remove('tasks')
          ..remove('approval'),
      );
      expect(legacy.boardVerification(active: false), isEmpty);
      expect(
        base.copy(tasks: BuildTask.starter).boardVerification(active: false),
        isEmpty,
      );
    },
  );

  testWidgets(
    'shared saved verification is readable at narrow enlarged text size',
    (tester) async {
      tester.view.physicalSize = const Size(320, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Future<void> show(GeneratedProject result, {bool active = false}) =>
          tester.pumpWidget(
            MaterialApp(
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: TextScaler.linear(2)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: BoardVerificationProgress(
                    result: result,
                    active: active,
                  ),
                ),
              ),
            ),
          );
      final partial = snapshot().copy(
        phase: SourceGenerationPhase.verifying,
        steps: steps(2),
      );
      await show(GeneratedProject.fromJson(partial.toJson()));
      expect(find.text('Tstarter: interrupted'), findsOneWidget);
      expect(find.text('2/4 mapped operations passed'), findsOneWidget);
      expect(
        find.textContaining('do not mark board tasks complete'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await show(partial, active: true);
      expect(find.text('Tstarter: running'), findsOneWidget);
      await show(
        partial.copy(
          phase: SourceGenerationPhase.failed,
          failedOperation: 'analyze',
        ),
      );
      expect(find.text('Tstarter: failed'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await show(snapshot().copy(tasks: BuildTask.starter));
      expect(find.text('Linked board task verification'), findsNothing);
    },
  );
}
