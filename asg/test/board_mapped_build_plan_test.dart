// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/build_plan.dart';
import 'package:asg/models/build_task.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:flutter_test/flutter_test.dart';

import 'mapped_build_plan_test.dart' show mappedContract, mappedContent;

Map<String, Object> boardContract() => {
  ...mappedContract(),
  'version': 3,
  'tasks': [
    for (final raw in mappedContract()['tasks'] as List)
      {...raw as Map, 'boardTaskId': 'T${raw['operation']}'},
  ],
};
String boardContent([Map<String, Object>? contract]) =>
    mappedContent(contract ?? boardContract());
RequirementsBoard mappedBoard({bool done = false}) => RequirementsBoard(
  requirements: const [
    ProjectRequirement(id: 'R1', title: 'Starter', acceptance: 'Verify output'),
  ],
  tasks: [
    for (final raw in mappedContract()['tasks'] as List)
      DevelopmentTask(
        id: 'T${raw['operation']}',
        requirementId: 'R1',
        title: '${raw['operation']}',
        dependencies: [
          for (final dep in raw['dependencies'] as List)
            for (final prior in mappedContract()['tasks'] as List)
              if (prior['id'] == dep) 'T${prior['operation']}',
        ],
        status: done ? TaskStatus.done : TaskStatus.queued,
      ),
  ],
);
Map<String, Object> sharedContract() => {
  ...mappedContract(),
  'version': 4,
  'tasks': [
    for (final raw in mappedContract()['tasks'] as List)
      {...raw as Map, 'boardTaskId': 'Tstarter'},
  ],
};
RequirementsBoard sharedBoard({bool done = false}) => RequirementsBoard(
  requirements: mappedBoard().requirements,
  tasks: [
    DevelopmentTask(
      id: 'Tstarter',
      requirementId: 'R1',
      title: 'Starter workflow',
      status: done ? TaskStatus.done : TaskStatus.queued,
    ),
  ],
);
void main() {
  test('mapping refusals explain correction without echoing proposal data', () {
    String refusal(String content, {RequirementsBoard? board}) {
      try {
        BuildPlan.parse(content, board: board);
        fail('Invalid mapping was accepted');
      } on FormatException catch (error) {
        return error.message;
      }
    }

    expect(refusal(boardContent()), contains('current requirements board'));
    final unknown = boardContent().replaceFirst('Ttest', 'PRIVATE_UNKNOWN');
    final missing = refusal(unknown, board: mappedBoard());
    expect(missing, contains('A mapped board task is missing'));
    expect(missing, isNot(contains('PRIVATE_UNKNOWN')));
    expect(
      refusal(
        boardContent({...sharedContract(), 'version': 3}),
        board: sharedBoard(),
      ),
      contains('Use version 4'),
    );
    final board = RequirementsBoard(
      requirements: sharedBoard().requirements,
      tasks: [
        DevelopmentTask(
          id: 'Tprior',
          requirementId: 'R1',
          title: 'PRIVATE_TITLE',
        ),
        DevelopmentTask(
          id: 'Tstarter',
          requirementId: 'R1',
          title: 'Starter',
          dependencies: ['Tprior'],
        ),
      ],
    );
    final prerequisite = refusal(boardContent(sharedContract()), board: board);
    expect(prerequisite, contains('Map every prerequisite operation'));
    expect(prerequisite, isNot(contains('PRIVATE_TITLE')));
    expect(
      refusal(boardContent(), board: RequirementsBoard(tasks: board.tasks)),
      contains('requirements board is invalid'),
    );
    expect(
      refusal(
        boardContent().replaceFirst('flutter-starter', 'PRIVATE_ADAPTER'),
      ),
      isNot(contains('PRIVATE_ADAPTER')),
    );
    expect(
      BuildPlan.parse(boardContent(), board: mappedBoard()).tasks.length,
      4,
    );
    expect(
      BuildPlan.parse(
        boardContent(sharedContract()),
        board: sharedBoard(),
      ).tasks.length,
      4,
    );
  });
  test('shared references require version 4 and preserve every operation', () {
    for (final done in [false, true]) {
      final plan = BuildPlan.parse(
        boardContent(sharedContract()),
        board: sharedBoard(done: done),
      );
      expect(plan.tasks.map((t) => t.boardTaskId), everyElement('Tstarter'));
      expect(plan.tasks.length, 4);
      expect(
        plan.matchesTasks(
          BuildTask.fromJson(
            jsonDecode(jsonEncode(plan.tasks.map((t) => t.toJson()).toList())),
          ),
        ),
        isTrue,
      );
    }
    for (final version in [1, 2, 3]) {
      expect(
        () => BuildPlan.parse(
          boardContent({...sharedContract(), 'version': version}),
          board: sharedBoard(),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => BuildPlan.parse(boardContent(sharedContract())),
      throwsFormatException,
    );
    final tasks = sharedContract()['tasks'] as List;
    for (final change in [
      {'boardTaskId': 'missing'},
      {'boardTaskId': null},
    ]) {
      expect(
        () => BuildPlan.parse(
          boardContent({
            ...sharedContract(),
            'tasks': [
              tasks.first,
              {...tasks[1] as Map, ...change},
              ...tasks.skip(2),
            ],
          }),
          board: sharedBoard(),
        ),
        throwsFormatException,
      );
    }
  });
  test('all shared prerequisite operations must precede each dependent', () {
    final board = RequirementsBoard(
      requirements: mappedBoard().requirements,
      tasks: [
        DevelopmentTask(id: 'Tprepare', requirementId: 'R1', title: 'Prepare'),
        DevelopmentTask(
          id: 'Tfinish',
          requirementId: 'R1',
          title: 'Finish',
          dependencies: ['Tprepare'],
        ),
      ],
    );
    Map<String, Object> contract({required bool complete}) => {
      ...sharedContract(),
      'tasks': [
        for (final raw in mappedContract()['tasks'] as List)
          {
            ...raw as Map,
            'boardTaskId': ['resolve', 'test'].contains(raw['operation'])
                ? 'Tprepare'
                : 'Tfinish',
            if (complete && raw['operation'] == 'analyze')
              'dependencies': ['unit'],
          },
      ],
    };
    expect(
      () => BuildPlan.parse(
        boardContent(contract(complete: false)),
        board: board,
      ),
      throwsFormatException,
    );
    expect(
      BuildPlan.parse(
        boardContent(contract(complete: true)),
        board: board,
      ).tasks.length,
      4,
    );
    final unmapped = RequirementsBoard(
      requirements: board.requirements,
      tasks: [
        DevelopmentTask(
          id: 'Texternal',
          requirementId: 'R1',
          title: 'External',
          status: TaskStatus.done,
        ),
        DevelopmentTask(
          id: 'Tstarter',
          requirementId: 'R1',
          title: 'Starter',
          dependencies: ['Texternal'],
        ),
      ],
    );
    expect(
      () => BuildPlan.parse(boardContent(sharedContract()), board: unmapped),
      throwsFormatException,
    );
  });
  test(
    'board references survive round trip without manual status skipping checks',
    () {
      for (final done in [false, true]) {
        final plan = BuildPlan.parse(
          boardContent(),
          board: mappedBoard(done: done),
        );
        expect(plan.tasks.map((t) => t.boardTaskId), [
          'Tresolve',
          'Ttest',
          'Tanalyze',
          'Tbuild',
        ]);
        expect(plan.tasks.length, 4);
        expect(plan.preview, contains('board task: Ttest'));
        expect(
          plan.matchesTasks(
            BuildTask.fromJson(
              jsonDecode(
                jsonEncode(plan.tasks.map((t) => t.toJson()).toList()),
              ),
            ),
          ),
          isTrue,
        );
        expect(
          plan.matchesTasks(BuildPlan.parse(mappedContent()).tasks),
          isFalse,
        );
      }
      expect(() => BuildPlan.parse(boardContent()), throwsFormatException);
    },
  );
  test('rejects absent duplicate mixed invalid and legacy references', () {
    final original = boardContract()['tasks'] as List;
    for (final change in [
      {'boardTaskId': 'missing'},
      {'boardTaskId': 'Tresolve'},
      {'boardTaskId': null},
      {'boardTaskId': '../Ttest'},
      {'boardTaskId': 1},
      {'command': 'arbitrary'},
    ]) {
      final value = {
        ...boardContract(),
        'tasks': [
          for (final raw in original)
            if (raw['id'] == 'unit') {...raw as Map, ...change} else raw,
        ],
      };
      expect(
        () => BuildPlan.parse(boardContent(value), board: mappedBoard()),
        throwsFormatException,
        reason: '$change',
      );
    }
    for (final version in [1, 2]) {
      expect(
        () => BuildPlan.parse(
          boardContent({...boardContract(), 'version': version}),
          board: mappedBoard(),
        ),
        throwsFormatException,
      );
    }
    expect(
      () => BuildPlan.parse(
        boardContent({
          ...boardContract(),
          'tasks': [
            for (final raw in original)
              if (raw['id'] == 'unit')
                {...raw as Map}..remove('boardTaskId')
              else
                raw,
          ],
        }),
        board: mappedBoard(),
      ),
      throwsFormatException,
    );
  });
  test('board prerequisites must be mapped transitively including manual completion', () {
    final board = mappedBoard();
    RequirementsBoard withDependencies(String id, List<String> dependencies) =>
        RequirementsBoard(
          requirements: board.requirements,
          tasks: [
            for (final t in board.tasks)
              if (t.id == id)
                DevelopmentTask(
                  id: t.id,
                  requirementId: t.requirementId,
                  title: t.title,
                  dependencies: dependencies,
                )
              else
                t,
          ],
        );
    expect(
      () => BuildPlan.parse(
        boardContent(),
        board: withDependencies('Tanalyze', ['Ttest']),
      ),
      throwsFormatException,
    );
    final external = RequirementsBoard(
      requirements: board.requirements,
      tasks: [
        ...withDependencies('Tresolve', ['Texternal']).tasks,
        DevelopmentTask(
          id: 'Texternal',
          requirementId: 'R1',
          title: 'Prerequisite',
          status: TaskStatus.done,
        ),
      ],
    );
    expect(
      () => BuildPlan.parse(boardContent(), board: external),
      throwsFormatException,
    );
    expect(
      BuildPlan.parse(
        boardContent(),
        board: withDependencies('Tbuild', ['Tresolve']),
      ).tasks.length,
      4,
    );
    expect(
      () => BuildPlan.parse(
        boardContent(),
        board: RequirementsBoard(tasks: board.tasks),
      ),
      throwsFormatException,
    );
  });
}
