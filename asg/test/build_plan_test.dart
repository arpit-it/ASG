import 'dart:convert';

import 'package:asg/models/build_plan.dart';
import 'package:asg/models/build_task.dart';
import 'package:asg/models/conversation_mode.dart';
import 'package:asg/models/project.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  String fence(Object value) => '```asg-build\n${jsonEncode(value)}\n```';
  Map<String, Object> graph() => {
    'version': 1,
    'adapter': 'flutter-starter',
    'tasks': BuildTask.starter.map((t) => t.toJson()).toList(),
  };
  test('converts bounded saved Plan contract into immutable typed tasks', () {
    final plan = BuildPlan.parse(
      '[Plan draft — not approved]\nTasks\n'
      '${BuildPlan.starterContract}\nReview before approval.',
    );
    expect(plan.tasks.map((t) => t.operation), BuildOperation.values);
    expect(plan.tasks.last.dependencies, ['starter-test']);
    expect(() => plan.tasks.clear(), throwsUnsupportedError);
    expect(
      BuildPlan.parse(BuildPlan.starterContract.replaceAll('\n', '\r\n'))
          .tasks
          .length,
      4,
    );
  });
  test(
    'rejects absent malformed duplicate oversized and unsupported contracts',
    () {
      for (final content in [
        'Implement anything',
        '```asg-build\n{}',
        '```asg-build\nnot json\n```',
        '${BuildPlan.starterContract}\n${BuildPlan.starterContract}',
        '${BuildPlan.starterContract}\n```asg-build extra',
        '${'x' * 65536}\n${BuildPlan.starterContract}',
        fence({...graph(), 'version': 3}),
        fence({...graph(), 'version': 1.0}),
        fence({...graph(), 'adapter': 'shell'}),
        fence({...graph(), 'command': 'arbitrary'}),
        fence({...graph(), 'tasks': []}),
      ]) {
        expect(
          () => BuildPlan.parse(content),
          throwsFormatException,
          reason: content.substring(0, content.length.clamp(0, 80)),
        );
      }
    },
  );
  test('rejects unknown operations and changed graph prerequisites', () {
    for (final field in ['id', 'operation', 'dependencies']) {
      final value = graph();
      ((value['tasks'] as List)[2] as Map)[field] = field == 'dependencies'
          ? ['starter-build']
          : 'shell';
      expect(() => BuildPlan.parse(fence(value)), throwsFormatException);
    }
  });
  test('rejects duplicate members including escaped equivalent names', () {
    final valid = BuildPlan.starterContract;
    for (final duplicate in [
      valid.replaceFirst('"version":1', '"version":2,"version":1'),
      valid.replaceFirst('"adapter":', '"adapter":"shell","adapter":'),
      valid.replaceFirst('"version":1', '"version":1,"version":1'),
      valid.replaceFirst('"version":1', r'"ver\u0073ion":1,"version":1'),
      valid.replaceFirst('"id":', '"id":"untrusted","id":'),
      valid.replaceFirst('"operation":', '"operation":"shell","operation":'),
      valid.replaceFirst(
        '"dependencies":[]',
        '"dependencies":[],"dependencies":[]',
      ),
    ]) {
      expect(() => BuildPlan.parse(duplicate), throwsFormatException);
    }
  });

  test('escaped unique keys preserve valid JSON semantics', () {
    final valid = BuildPlan.starterContract.replaceFirst(
      '"version":',
      r'"ver\u0073ion":',
    );
    expect(BuildPlan.parse(valid).tasks.length, 4);
    final value = graph()..['adapter'] = r'brace } { "version":1, \"';
    expect(() => BuildPlan.parse(fence(value)), throwsFormatException);
    for (final invalid in ['{"version":', '{"version":1,}']) {
      expect(
        () => BuildPlan.parse('```asg-build\n$invalid\n```'),
        throwsFormatException,
      );
    }
  });
  test('Plan prompt scopes contract to explicit supported requests only', () {
    final instructions = ConversationMode.plan.instructions;
    expect(instructions, contains(BuildPlan.starterContract));
    expect(instructions, contains('omit the contract'));
    expect(instructions, contains('never approval'));
    expect(ConversationMode.discuss.instructions, isNot(contains('asg-build')));
    expect(ConversationMode.review.instructions, isNot(contains('asg-build')));
  });
}
