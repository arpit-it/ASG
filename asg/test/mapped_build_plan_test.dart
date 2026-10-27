// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/build_plan.dart';
import 'package:asg/models/build_task.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object> mappedContract() => {
  'version': 2,
  'adapter': 'flutter-starter',
  'tasks': [
    {'id': 'deps', 'operation': 'resolve', 'dependencies': []},
    {
      'id': 'unit',
      'operation': 'test',
      'dependencies': ['deps'],
    },
    {
      'id': 'lint',
      'operation': 'analyze',
      'dependencies': ['deps'],
    },
    {
      'id': 'release',
      'operation': 'build',
      'dependencies': ['unit', 'lint'],
    },
  ],
};
String mappedContent([Map<String, Object>? value]) =>
    '```asg-build\n${jsonEncode(value ?? mappedContract())}\n```';

void main() {
  test(
    'maps named tasks with explicit prerequisites and immutable round trip',
    () {
      final plan = BuildPlan.parse(mappedContent());
      expect(plan.tasks.map((t) => t.operation.name), [
        'resolve',
        'test',
        'analyze',
        'build',
      ]);
      expect(
        plan.preview,
        contains('release: Build Flutter web output; depends on: unit, lint'),
      );
      expect(
        plan.matchesTasks(BuildTask.fromJson(mappedContract()['tasks'])),
        isTrue,
      );
      expect(plan.matchesTasks(BuildTask.starter), isFalse);
      expect(
        () => plan.tasks.last.dependencies.clear(),
        throwsUnsupportedError,
      );
      expect(
        () =>
            BuildPlan.parse(mappedContent({...mappedContract(), 'version': 1})),
        throwsFormatException,
      );
    },
  );

  test(
    'rejects invalid identities, operations and unsafe dependency graphs',
    () {
      final original = mappedContract()['tasks'] as List;
      final changes = <Map<String, Object>>[
        {'id': 'unit'},
        {'id': ''},
        {'id': '../lint'},
        {'id': 'a' * 65},
        {'operation': 'test'},
        {'operation': 'shell'},
        {'dependencies': []},
        {
          'dependencies': ['release'],
        },
        {
          'dependencies': ['lint'],
        },
        {
          'dependencies': ['missing'],
        },
        {
          'dependencies': ['deps', 'deps'],
        },
        {
          'dependencies': [1],
        },
        {'command': 'echo arbitrary'},
      ];
      for (final change in changes) {
        final tasks = [
          for (final raw in original)
            if ((raw as Map)['id'] == 'lint') {...raw, ...change} else raw,
        ];
        expect(
          () => BuildPlan.parse(
            mappedContent({...mappedContract(), 'tasks': tasks}),
          ),
          throwsFormatException,
          reason: '$change',
        );
      }
      for (final dependencies in [
        ['unit'],
        ['lint'],
        [],
      ]) {
        final tasks = [
          for (final raw in original)
            if ((raw as Map)['id'] == 'release')
              {...raw, 'dependencies': dependencies}
            else
              raw,
        ];
        expect(
          () => BuildPlan.parse(
            mappedContent({...mappedContract(), 'tasks': tasks}),
          ),
          throwsFormatException,
        );
      }
      expect(
        () => BuildPlan.parse(
          mappedContent({
            ...mappedContract(),
            'tasks': original.take(3).toList(),
          }),
        ),
        throwsFormatException,
      );
      final transitive = [
        for (final raw in original)
          if ((raw as Map)['id'] == 'lint')
            {
              ...raw,
              'dependencies': ['unit'],
            }
          else if (raw['id'] == 'release')
            {
              ...raw,
              'dependencies': ['lint'],
            }
          else
            raw,
      ];
      expect(
        BuildPlan.parse(
          mappedContent({...mappedContract(), 'tasks': transitive}),
        ).tasks.length,
        4,
      );
    },
  );
}
