import 'package:asg/models/build_task.dart';
import 'package:asg/models/plan_approval.dart';
import 'package:asg/models/source_generation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final approval = PlanApproval(
    messageIndex: 2,
    content: 'Starter',
    context: 'revision 3',
    approved: true,
    recordedAt: DateTime.utc(2026),
  );
  GeneratedProject snapshot() => GeneratedProject(
    directory: '/project',
    sdk: '/sdk',
    python: 'python3',
    sources: {'main.dart': '0' * 64},
    approval: approval,
    tasks: BuildTask.starter,
  );
  GenerationStep step(String op, int code) =>
      GenerationStep(operation: op, exitCode: code, output: 'actual result');

  test(
    'canonical task graph persists with exact approval and immutable tasks',
    () {
      final restored = GeneratedProject.fromJson(snapshot().toJson());
      expect(restored.approval!.matches(approval), isTrue);
      expect(restored.tasks!.map((t) => t.id), [
        'starter-resolve',
        'starter-analyze',
        'starter-test',
        'starter-build',
      ]);
      expect(restored.tasks![2].dependencies, ['starter-analyze']);
      expect(() => restored.tasks!.clear(), throwsUnsupportedError);
      expect(
        restored.taskStatus(restored.tasks!.first, active: false),
        BuildTaskStatus.pending,
      );
    },
  );

  test('tampered IDs operations order dependencies and missing approval fail closed', () {
    for (final field in ['id', 'operation', 'dependencies']) {
      final json = snapshot().toJson();
      final tasks = json['tasks'] as List;
      (tasks[1] as Map)[field] = field == 'dependencies'
          ? ['starter-build']
          : 'shell';
      expect(() => GeneratedProject.fromJson(json), throwsFormatException);
    }
    final reordered = snapshot().toJson();
    final tasks = reordered['tasks'] as List;
    final first = tasks.removeAt(0);
    tasks.add(first);
    expect(() => GeneratedProject.fromJson(reordered), throwsFormatException);
    expect(
      () => GeneratedProject.fromJson(snapshot().toJson()..remove('approval')),
      throwsFormatException,
    );
    expect(
      () => GeneratedProject.fromJson(<String, dynamic>{
        ...snapshot().toJson(),
        'tasks': null,
      }),
      throwsFormatException,
    );
  });

  test('actual command outcomes determine progress and failed dependencies block later tasks', () {
    final running = snapshot().copy(
      phase: SourceGenerationPhase.verifying,
      steps: [step('resolve', 0)],
    );
    expect(
      running.taskStatus(running.tasks![0], active: true),
      BuildTaskStatus.passed,
    );
    expect(
      running.taskStatus(running.tasks![1], active: true),
      BuildTaskStatus.running,
    );
    expect(
      running.taskStatus(running.tasks![1], active: false),
      BuildTaskStatus.interrupted,
    );
    expect(
      running.taskStatus(running.tasks![2], active: true),
      BuildTaskStatus.pending,
    );
    final failed = running.copy(
      phase: SourceGenerationPhase.failed,
      steps: [step('resolve', 0), step('analyze', 1)],
    );
    expect(
      failed.taskStatus(failed.tasks![1], active: false),
      BuildTaskStatus.failed,
    );
    expect(
      failed.taskStatus(failed.tasks![2], active: false),
      BuildTaskStatus.blocked,
    );
    expect(
      failed.taskStatus(failed.tasks![3], active: false),
      BuildTaskStatus.blocked,
    );
  });

  test('runner failure identity persists without invented exit evidence', () {
    final failed = snapshot().copy(
      phase: SourceGenerationPhase.failed,
      steps: [step('resolve', 0)],
      failedOperation: 'analyze',
      error: 'Unavailable',
    );
    final restored = GeneratedProject.fromJson(failed.toJson());
    expect(restored.steps.length, 1);
    expect(
      restored.taskStatus(restored.tasks![0], active: false),
      BuildTaskStatus.passed,
    );
    expect(
      restored.taskStatus(restored.tasks![1], active: false),
      BuildTaskStatus.failed,
    );
    expect(
      restored.taskStatus(restored.tasks![2], active: false),
      BuildTaskStatus.blocked,
    );
    for (final invalid in [
      {...failed.toJson(), 'failedOperation': 'shell'},
      {...failed.toJson(), 'failedOperation': 'test'},
      {...failed.toJson(), 'phase': 'verifying'},
      {
        ...failed.toJson(),
        'steps': [step('resolve', 1).toJson()],
      },
    ]) {
      expect(() => GeneratedProject.fromJson(invalid), throwsFormatException);
    }
  });

  test('output exhaustion persists as failure even with a zero exit code', () {
    const exhausted = GenerationStep(
      operation: 'resolve',
      exitCode: 0,
      output: 'bounded output',
      outputLimitExceeded: true,
    );
    final failed = snapshot().copy(
      phase: SourceGenerationPhase.failed,
      steps: [exhausted],
    );
    final restored = GeneratedProject.fromJson(failed.toJson());
    expect(restored.steps.single.outputLimitExceeded, isTrue);
    expect(
      restored.taskStatus(restored.tasks![0], active: false),
      BuildTaskStatus.failed,
    );
    expect(
      restored.taskStatus(restored.tasks![1], active: false),
      BuildTaskStatus.blocked,
    );
    expect(
      () => GeneratedProject.fromJson(
        failed.copy(steps: [exhausted, step('analyze', 0)]).toJson(),
      ),
      throwsFormatException,
    );
    expect(
      () => GeneratedProject.fromJson(
        failed
            .copy(
              phase: SourceGenerationPhase.ready,
              steps: [
                exhausted,
                step('analyze', 0),
                step('test', 0),
                step('build', 0),
              ],
              outputs: {'index.html': '0' * 64, 'main.dart.js': '0' * 64},
            )
            .toJson(),
      ),
      throwsFormatException,
    );
    final legacy = step('resolve', 0).toJson()..remove('outputLimitExceeded');
    expect(GenerationStep.fromJson(legacy).succeeded, isTrue);
  });

  test('downstream results after failed dependency are rejected', () {
    final invalid = snapshot().copy(
      phase: SourceGenerationPhase.failed,
      steps: [step('resolve', 1), step('analyze', 0)],
    );
    expect(
      () => GeneratedProject.fromJson(invalid.toJson()),
      throwsFormatException,
    );
  });

  test(
    'legacy records retain compatibility without invented task provenance',
    () {
      final legacy = snapshot().toJson()
        ..remove('tasks')
        ..remove('approval');
      final restored = GeneratedProject.fromJson(legacy);
      expect(restored.tasks, isNull);
      expect(restored.approval, isNull);
    },
  );
}
