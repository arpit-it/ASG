// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/agent_task_history.dart';
import 'package:asg/models/agent_session.dart';
import 'package:asg/models/build_task.dart';

import 'agent_session_test.dart' as fixture;

import 'package:flutter_test/flutter_test.dart';

AgentSession basis() => fixture.session().observe(
  AgentSessionDispatch(
    boardTaskId: 'T1',
    runNumber: 1,
    dispatchId: 'candidate-p-1:3',
  ),
);
AgentTaskHistory start(AgentSession session) => AgentTaskHistory.start(
  session: session,
  reference: session.dispatches.last,
);
AgentTaskObservation event(
  int sequence,
  String kind, [
  String? operation,
  int? exit,
  bool? cancelled,
]) => AgentTaskObservation.fromJson({
  'sequence': sequence,
  'kind': kind,
  'operation': operation,
  'exitCode': exit,
  'cancelled': cancelled,
});
AgentTaskHistory add(
  AgentTaskHistory h,
  AgentSession s,
  String kind, [
  String? op,
  int? exit,
  bool? cancelled,
]) => h.append(
  event(h.observations.length, kind, op, exit, cancelled),
  currentSession: s,
);

void main() {
  Map<String, dynamic> unknown() => {
    'sequence': 5,
    'kind': 'interrupted',
    'operation': 'test',
    'exitCode': null,
    'cancelled': null,
  };

  test('interruption cannot invent an exit or cancellation result', () {
    final raw = unknown();
    final value = AgentTaskObservation.fromJson(raw);
    expect(value.exitCode, isNull);
    expect(value.cancelled, isNull);
    for (final fields in [
      {'exitCode': 0},
      {'exitCode': 73},
      {'cancelled': true},
      {'cancelled': false},
    ]) {
      expect(
        () => AgentTaskObservation.fromJson({...raw, ...fields}),
        throwsFormatException,
      );
    }
    raw['operation'] = 'build';
    final copy = value.toJson()..['kind'] = 'result';
    expect(value.toJson()['operation'], 'test');
    expect(value.toJson()['kind'], 'interrupted');
    expect(copy['kind'], 'result');
  });

  test('actual supplied result retains exit and cancellation separately', () {
    final raw = {
      ...unknown(),
      'kind': 'result',
      'exitCode': -1,
      'cancelled': true,
    };
    final value = AgentTaskObservation.fromJson(raw);
    expect(value.toJson(), raw);
    expect(AgentTaskObservation.fromJson(value.toJson()).toJson(), raw);
    for (final fields in [
      {'exitCode': null},
      {'exitCode': true},
      {'exitCode': 1.0},
      {'exitCode': 2147483648},
      {'cancelled': null},
      {'cancelled': 0},
    ]) {
      expect(
        () => AgentTaskObservation.fromJson({...raw, ...fields}),
        throwsFormatException,
      );
    }
  });

  test('unbounded positions and unknown operations or fields are refused', () {
    for (final fields in [
      {'sequence': -1},
      {'sequence': 16},
      {'sequence': true},
      {'sequence': 0},
      {'kind': 'completed'},
      {'operation': 'shell'},
      {'operation': null},
      {'command': 'ignored command'},
    ]) {
      expect(
        () => AgentTaskObservation.fromJson({...unknown(), ...fields}),
        throwsFormatException,
      );
    }
    final missing = unknown()..remove('exitCode');
    expect(() => AgentTaskObservation.fromJson(missing), throwsFormatException);
  });
  test('whole fixed sequence roundtrips with immutable identity and no task completion', () {
    final session = basis(), before = jsonEncode(basis().toJson());
    var h = start(session);
    for (final op in BuildOperation.values) {
      h = add(h, session, 'pending', op.name);
      h = add(h, session, 'result', op.name, 0, false);
    }
    h = add(h, session, 'finished');
    expect(h.finished, isTrue);
    expect(h.pendingOperation, isNull);
    expect(h.results.length, 4);
    final wire = jsonDecode(jsonEncode(h.toJson()));
    expect(
      AgentTaskHistory.fromJson(wire, currentSession: session).toJson(),
      h.toJson(),
    );
    expect(jsonEncode(session.toJson()), before);
    expect(session.toJson().length, 8);
    expect(() => h.observations.clear(), throwsUnsupportedError);
    expect(() => h.results.clear(), throwsUnsupportedError);
    (wire['observations'] as List).clear();
    expect(h.observations.length, 10);
    expect(() => add(h, session, 'pending', 'resolve'), throwsFormatException);
  });

  test(
    'unknown interruption preserves prefix and never authorizes resumed work',
    () {
      final session = basis();
      var h = add(start(session), session, 'pending', 'resolve');
      h = add(h, session, 'result', 'resolve', 0, false);
      h = add(h, session, 'pending', 'analyze');
      h = add(h, session, 'interrupted', 'analyze');
      final before = h.toJson();
      expect(h.pendingOperation, BuildOperation.analyze);
      expect(h.results.single.exitCode, 0);
      expect(h.observations.last.exitCode, isNull);
      expect(h.finished, isFalse);
      expect(() => add(h, session, 'finished'), throwsFormatException);
      expect(
        () => add(h, session, 'interrupted', 'analyze'),
        throwsFormatException,
      );
      expect(
        () => add(h, session, 'result', 'test', 0, false),
        throwsFormatException,
      );
      final late = add(h, session, 'result', 'analyze', 0, false);
      expect(late.pendingOperation, isNull);
      expect(
        () => add(late, session, 'pending', 'test'),
        throwsFormatException,
      );
      expect(add(late, session, 'finished').finished, isTrue);
      expect(h.toJson(), before);
    },
  );

  test('withdrawal keeps actual test result or unknown separately and blocks Build', () {
    final session = basis(), cancelled = basis().requestCancellation();
    var h = start(session);
    for (final op in ['resolve', 'analyze']) {
      h = add(h, session, 'pending', op);
      h = add(h, session, 'result', op, 0, false);
    }
    h = add(h, session, 'pending', 'test');
    final withdrawn = h.observeWithdrawal(currentSession: cancelled);
    expect(withdrawn.withdrawalSequence, 6);
    expect(
      withdrawn.observeWithdrawal(currentSession: cancelled).toJson(),
      withdrawn.toJson(),
    );
    final late = add(withdrawn, cancelled, 'result', 'test', 0, false);
    expect(late.results.last.exitCode, 0);
    expect(late.results.last.cancelled, isFalse);
    expect(
      () => add(late, cancelled, 'pending', 'build'),
      throwsFormatException,
    );
    expect(() => add(late, session, 'finished'), throwsFormatException);
    expect(add(late, cancelled, 'finished').finished, isTrue);
    expect(
      AgentTaskHistory.fromJson(
        late.toJson(),
        currentSession: cancelled,
      ).toJson(),
      late.toJson(),
    );
    final unknown = add(h, cancelled, 'interrupted', 'test');
    expect(unknown.results.length, 2);
    expect(unknown.pendingOperation, BuildOperation.test);
    expect(unknown.observations.last.exitCode, isNull);
    expect(unknown.observations.last.cancelled, isNull);
    expect(() => add(unknown, cancelled, 'finished'), throwsFormatException);
    expect(
      () => add(unknown, cancelled, 'pending', 'build'),
      throwsFormatException,
    );
    expect(
      () => AgentTaskHistory.fromJson(late.toJson(), currentSession: session),
      throwsFormatException,
    );
    expect(
      () => AgentTaskHistory.start(
        session: cancelled,
        reference: cancelled.dispatches.last,
      ),
      throwsFormatException,
    );
    expect(
      () => start(session).observeWithdrawal(currentSession: session),
      throwsFormatException,
    );
  });

  test('failed or cancelled actual result finishes without enabling next operation', () {
    final session = basis();
    for (final result in [(1, false), (-1, true), (0, true)]) {
      var h = add(start(session), session, 'pending', 'resolve');
      h = add(h, session, 'result', 'resolve', result.$1, result.$2);
      expect(h.results.single.exitCode, result.$1);
      expect(
        () => add(h, session, 'pending', 'analyze'),
        throwsFormatException,
      );
      expect(add(h, session, 'finished').finished, isTrue);
    }
    expect(add(start(session), session, 'finished').results, isEmpty);
  });

  test('session approval graph reference and current snapshot cannot be substituted', () {
    final session = basis(), h = start(basis());
    final wire = session.toJson();
    for (final current in [
      AgentSession.fromJson({...wire, 'sessionId': 'another'}),
      AgentSession.fromJson({
        ...wire,
        'approval': {...session.approval.toJson(), 'content': 'Changed'},
      }),
      AgentSession.fromJson({
        ...wire,
        'tasks': [
          {'id': 'T1', 'requirementId': 'R2', 'dependencies': <String>[]},
        ],
      }),
      session.observe(
        AgentSessionDispatch(
          boardTaskId: 'T1',
          runNumber: 2,
          dispatchId: 'candidate-p-2:3',
        ),
      ),
    ]) {
      expect(
        () => AgentTaskHistory.fromJson(h.toJson(), currentSession: current),
        throwsFormatException,
      );
    }
    expect(
      () => AgentTaskHistory.start(
        session: fixture.session(),
        reference: session.dispatches.last,
      ),
      throwsFormatException,
    );
    expect(
      () => AgentTaskHistory.fromJson({
        ...h.toJson(),
        'reference': {
          'boardTaskId': 'T1',
          'runNumber': 2,
          'dispatchId': 'candidate-p-2:3',
        },
      }, currentSession: session),
      throwsFormatException,
    );
  });

  test('causal gaps duplicates reordered operations and unknown-finished states refuse', () {
    final session = basis();
    final h = add(start(session), session, 'pending', 'resolve');
    final wire = h.toJson(),
        first = h.observations.first.toJson(),
        pending = h.observations.last.toJson();
    for (final events in [
      <Object>[],
      [pending],
      [
        first,
        {...pending, 'sequence': 2},
      ],
      [
        first,
        pending,
        {...pending, 'sequence': 2},
      ],
      [
        first,
        {...pending, 'operation': 'analyze'},
      ],
      [first, event(1, 'result', 'resolve', 0, false).toJson()],
      [first, pending, event(2, 'finished').toJson()],
      [
        first,
        event(1, 'finished').toJson(),
        event(2, 'pending', 'resolve').toJson(),
      ],
      List.generate(17, (_) => first),
    ]) {
      expect(
        () => AgentTaskHistory.fromJson({
          ...wire,
          'observations': events,
        }, currentSession: session),
        throwsFormatException,
      );
    }
    expect(
      () => h.append(
        event(3, 'result', 'resolve', 0, false),
        currentSession: session,
      ),
      throwsFormatException,
    );
    for (final boundary in [0, -1, 3, true, '1', 1]) {
      expect(
        () => AgentTaskHistory.fromJson({
          ...wire,
          'withdrawalSequence': boundary,
        }, currentSession: session.requestCancellation()),
        throwsFormatException,
      );
    }
  });

  test(
    'record fields size and nested collections are bounded and immutable',
    () {
      final session = basis(), h = start(basis());
      final raw = h.toJson();
      for (final altered in [
        {...raw, 'version': true},
        {...raw, 'version': 2},
        {...raw, 'command': 'ignored'},
        {...raw, 'observations': null},
        {...raw, 'session': null},
        {...raw, 'reference': null},
        {
          ...raw,
          'session': {'padding': 'x' * AgentTaskHistory.maxEncodedBytes},
        },
      ]) {
        expect(
          () => AgentTaskHistory.fromJson(altered, currentSession: session),
          throwsFormatException,
        );
      }
      expect(
        () => AgentTaskHistory.fromJson(
          {...raw}..remove('withdrawalSequence'),
          currentSession: session,
        ),
        throwsFormatException,
      );
      ((raw['session'] as Map)['tasks'] as List).clear();
      expect(h.session.tasks.items.single.id, 'T1');
    },
  );
  test('read-only old history stays historical while new pending observes withdrawal', () {
    final session = basis(), cancelled = basis().requestCancellation();
    final original = start(session);
    final reopened = AgentTaskHistory.fromJson(
      original.toJson(),
      currentSession: cancelled,
    );
    expect(reopened.toJson(), original.toJson());
    expect(reopened.withdrawalSequence, isNull);
    expect(
      () => add(reopened, cancelled, 'pending', 'resolve'),
      throwsFormatException,
    );
    final withdrawn = reopened.observeWithdrawal(currentSession: cancelled);
    expect(withdrawn.withdrawalSequence, 1);
    expect(withdrawn.observations.length, 1);
    expect(
      () => AgentTaskHistory.fromJson(
        withdrawn.toJson(),
        currentSession: session,
      ),
      throwsFormatException,
    );
  });

  test(
    'JSON parser rejects non-JSON payloads without changing existing history',
    () {
      final session = basis(), original = start(basis());
      final before = original.toJson();
      for (final invalid in [
        null,
        true,
        <Object>[],
        {...before, 'reference': Object()},
      ]) {
        expect(
          () => AgentTaskHistory.fromJson(invalid, currentSession: session),
          throwsFormatException,
        );
      }
      expect(original.toJson(), before);
    },
  );
  test(
    'v2 preserves approved test-before-analysis order while v1 stays canonical',
    () {
      final session = basis();
      var h = AgentTaskHistory.start(
        session: session,
        reference: session.dispatches.last,
        operationOrder: [
          BuildOperation.resolve,
          BuildOperation.test,
          BuildOperation.analyze,
          BuildOperation.build,
        ],
      );
      for (final op in h.operationOrder) {
        h = add(h, session, 'pending', op.name);
        h = add(h, session, 'result', op.name, 0, false);
      }
      expect(h.version, 2);
      expect(
        AgentTaskHistory.fromJson(h.toJson(), currentSession: session).toJson(),
        h.toJson(),
      );
      expect(() => h.operationOrder.clear(), throwsUnsupportedError);
      final legacy = start(session);
      expect(legacy.version, 1);
      expect(legacy.toJson().containsKey('operationOrder'), isFalse);
      expect(
        AgentTaskHistory.fromJson(
          legacy.toJson(),
          currentSession: session,
        ).toJson(),
        legacy.toJson(),
      );
      for (final order in [
        <String>[],
        ['resolve', 'test', 'test', 'build'],
        ['test', 'resolve', 'analyze', 'build'],
        ['resolve', 'analyze', 'build', 'test'],
        ['resolve', 'shell', 'analyze', 'build'],
      ]) {
        expect(
          () => AgentTaskHistory.fromJson({
            ...h.toJson(),
            'operationOrder': order,
          }, currentSession: session),
          throwsFormatException,
        );
      }
    },
  );
}
