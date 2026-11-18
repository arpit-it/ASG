// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/agent_session.dart';
import 'package:asg/models/plan_approval.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object> task(String id, [List<String> dependencies = const []]) => {
  'id': id,
  'requirementId': 'R1',
  'dependencies': dependencies,
};

AgentSession session() => AgentSession.create(
  sessionId: 'session-1',
  projectId: 'p',
  approval: PlanApproval(
    messageIndex: 0,
    content: 'Approved plan',
    context: 'Current project',
    approved: true,
    recordedAt: DateTime.utc(2026),
  ),
  tasks: AgentSessionTasks.fromJson([task('T1')]),
);

void main() {
  test('freezes selected membership separately from authored status', () {
    final selected = [
      DevelopmentTask(id: 'T1', requirementId: 'R1', title: 'First'),
      DevelopmentTask(
        id: 'T2',
        requirementId: 'R1',
        title: 'Next',
        dependencies: ['T1'],
        status: TaskStatus.done,
      ),
    ];
    final snapshot = AgentSessionTasks.fromBoardTasks(selected);
    selected.clear();
    expect(snapshot.items.map((item) => item.id), ['T1', 'T2']);
    expect(snapshot.toJson().last.containsKey('status'), isFalse);
    final reopened = AgentSessionTasks.fromJson(
      jsonDecode(jsonEncode(snapshot.toJson())),
    );
    expect(reopened.toJson(), snapshot.toJson());
    expect(() => snapshot.items.clear(), throwsUnsupportedError);
    expect(
      () => snapshot.items.last.dependencies.clear(),
      throwsUnsupportedError,
    );
    snapshot.toJson().last['dependencies'] = <String>[];
    expect(snapshot.items.last.dependencies, ['T1']);
  });

  test('rejects duplicate, unknown, self and cyclic dependency membership', () {
    for (final value in [
      [task('T1'), task('T1')],
      [
        task('T1', ['missing']),
      ],
      [
        task('T1', ['T1']),
      ],
      [
        task('T1', ['T2']),
        task('T2', ['T1']),
      ],
      [
        task('T1'),
        task('T2', ['T1', 'T1']),
      ],
    ]) {
      expect(() => AgentSessionTasks.fromJson(value), throwsFormatException);
    }
  });

  test('strict task parser rejects malformed and extra fields', () {
    for (final value in [
      null,
      'task',
      <String, Object>{},
      {...task('T1'), 'extra': true},
      {...task('T1'), 'id': '../T1'},
      {...task('T1'), 'requirementId': ''},
      {
        ...task('T1'),
        'dependencies': [false],
      },
    ]) {
      expect(() => AgentSessionTask.fromJson(value), throwsFormatException);
    }
  });

  test('bounds dependency traversal to a nonempty 64-task snapshot', () {
    expect(() => AgentSessionTasks.fromJson([]), throwsFormatException);
    final chain = [
      for (var i = 0; i < 64; i++) task('T$i', i == 0 ? [] : ['T${i - 1}']),
    ];
    expect(AgentSessionTasks.fromJson(chain).items.length, 64);
    expect(
      () => AgentSessionTasks.fromJson([
        ...chain,
        task('T64', ['T63']),
      ]),
      throwsFormatException,
    );
  });
  test(
    'session observations and cancellation are immutable, not completion',
    () {
      final initial = session();
      final observed = initial.observe(
        AgentSessionDispatch(
          boardTaskId: 'T1',
          runNumber: 1,
          dispatchId: 'candidate-p-1:3',
        ),
      );
      final cancelled = observed.requestCancellation();
      expect(initial.revision, 0);
      expect(initial.dispatches, isEmpty);
      expect(cancelled.revision, 2);
      expect(cancelled.cancellationRequested, isTrue);
      expect(
        AgentSession.fromJson(jsonDecode(jsonEncode(cancelled.toJson())))
            .toJson(),
        cancelled.toJson(),
      );
      expect(() => cancelled.dispatches.clear(), throwsUnsupportedError);
      expect(
        () => cancelled.observe(
          AgentSessionDispatch(
            boardTaskId: 'T1',
            runNumber: 2,
            dispatchId: 'candidate-p-2:3',
          ),
        ),
        throwsStateError,
      );
      expect(() => cancelled.requestCancellation(), throwsStateError);
      expect(cancelled.toJson().containsKey('completed'), isFalse);
    },
  );

  test(
    'session rejects forged dispatch/project/member/revision and consent',
    () {
      final initial = session();
      for (final reference in [
        AgentSessionDispatch(
          boardTaskId: 'other',
          runNumber: 1,
          dispatchId: 'candidate-p-1:3',
        ),
        AgentSessionDispatch(
          boardTaskId: 'T1',
          runNumber: 1,
          dispatchId: 'candidate-other-1:3',
        ),
        AgentSessionDispatch(
          boardTaskId: 'T1',
          runNumber: 2,
          dispatchId: 'candidate-p-1:3',
        ),
        AgentSessionDispatch(
          boardTaskId: 'T1',
          runNumber: 1,
          dispatchId: 'candidate-p-1:4',
        ),
      ]) {
        expect(() => initial.observe(reference), throwsFormatException);
      }
      for (final change in [
        {'revision': 1},
        {'version': 1.0},
        {'extra': true},
        {'sessionId': '../secret'},
        {
          'approval': {...initial.approval.toJson(), 'approved': false},
        },
        {
          'approval': {
            ...initial.approval.toJson(),
            'recordedAt': '2026-01-01T00:00:00+00:00',
          },
        },
      ]) {
        expect(
          () => AgentSession.fromJson({...initial.toJson(), ...change}),
          throwsFormatException,
        );
      }
      final reference = AgentSessionDispatch(
        boardTaskId: 'T1',
        runNumber: 1,
        dispatchId: 'candidate-p-1:3',
      );
      expect(
        () => initial.observe(reference).observe(reference),
        throwsFormatException,
      );
    },
  );

  test('bounds saved observation count and UTF8 approval bytes', () {
    var current = session();
    for (var i = 1; i <= AgentSession.maxDispatches; i++) {
      current = current.observe(
        AgentSessionDispatch(
          boardTaskId: 'T1',
          runNumber: i,
          dispatchId: 'candidate-p-$i:3',
        ),
      );
    }
    expect(current.dispatches.length, 128);
    expect(
      () => current.observe(
        AgentSessionDispatch(
          boardTaskId: 'T1',
          runNumber: 129,
          dispatchId: 'candidate-p-129:3',
        ),
      ),
      throwsFormatException,
    );
    final initial = session();
    expect(
      () => AgentSession.fromJson({
        ...initial.toJson(),
        'approval': {
          ...initial.approval.toJson(),
          'content': 'é' * (32 * 1024 + 1),
        },
      }),
      throwsFormatException,
    );
    expect(
      () => AgentSession.fromJson({
        ...initial.toJson(),
        'padding': 'x' * AgentSession.maxEncodedBytes,
      }),
      throwsFormatException,
    );
  });
  test('encoded session limit also bounds a valid dense dependency graph', () {
    final ids = [
      for (var i = 0; i < 64; i++) 'T${i.toString().padLeft(127, '0')}',
    ];
    final graph = AgentSessionTasks.fromJson([
      for (var i = 0; i < ids.length; i++) task(ids[i], ids.take(i).toList()),
    ]);
    final initial = session();
    expect(
      utf8
          .encode(jsonEncode({...initial.toJson(), 'tasks': graph.toJson()}))
          .length,
      greaterThan(AgentSession.maxEncodedBytes),
    );
    expect(
      () =>
          AgentSession.fromJson({...initial.toJson(), 'tasks': graph.toJson()}),
      throwsFormatException,
    );
  });
  test(
    'catalog freezes distinct bounded IDs without granting session authority',
    () {
      final empty = AgentSessionCatalog.empty('p');
      final first = empty.adding('s1');
      expect(empty.sessionIds, isEmpty);
      expect(first.sessionIds, ['s1']);
      expect(() => first.sessionIds.clear(), throwsUnsupportedError);
      expect(() => first.adding('s1'), throwsStateError);
      final full = AgentSessionCatalog.fromJson({
        'version': 1,
        'projectId': 'p',
        'sessionIds': [for (var i = 0; i < 128; i++) 's$i'],
      });
      expect(() => full.adding('extra'), throwsFormatException);
      expect(
        () => AgentSessionCatalog.fromJson({...first.toJson(), 'extra': true}),
        throwsFormatException,
      );
      expect(
        () => AgentSessionCatalog.fromJson({
          ...first.toJson(),
          'sessionIds': ['s1', 's1'],
        }),
        throwsFormatException,
      );
    },
  );
}
