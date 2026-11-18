// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/agent_session.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_session_test.dart' show session, task;

AgentSessionDispatch observed(int run, {String taskId = 'T1'}) =>
    AgentSessionDispatch(
      boardTaskId: taskId,
      runNumber: run,
      dispatchId: 'candidate-p-$run:3',
    );

void main() {
  test('selection refuses another project, excluded task and cancellation', () {
    final saved = session();
    final binding = AgentSessionBinding.select(
      session: saved,
      projectId: 'p',
      boardTaskId: 'T1',
    );
    expect(binding.admittedDispatchId, isNull);
    expect(binding.session.toJson(), saved.toJson());
    for (final selection in [
      () => AgentSessionBinding.select(
        session: saved,
        projectId: 'other',
        boardTaskId: 'T1',
      ),
      () => AgentSessionBinding.select(
        session: saved,
        projectId: 'p',
        boardTaskId: 'missing',
      ),
      () => AgentSessionBinding.select(
        session: saved.requestCancellation(),
        projectId: 'p',
        boardTaskId: 'T1',
      ),
    ]) {
      expect(selection, throwsFormatException);
    }
  });

  test('one appended reference advances binding immutably through explicit retries', () {
    final saved = session();
    final binding = AgentSessionBinding.select(
      session: saved,
      projectId: 'p',
      boardTaskId: 'T1',
    );
    final first = binding.admitted(
      saved.observe(observed(1)),
      'candidate-p-1:3',
    );
    final next = first.admitted(
      first.session.observe(observed(2)),
      'candidate-p-2:3',
    );
    expect(binding.session.dispatches, isEmpty);
    expect(first.session.dispatches, hasLength(1));
    expect(next.session.dispatches, hasLength(2));
    expect(next.admittedDispatchId, 'candidate-p-2:3');
    expect(() => next.session.dispatches.clear(), throwsUnsupportedError);
  });

  test('admission refuses wrong identity, no append, cancellation and wrong dispatch', () {
    final saved = session();
    final binding = AgentSessionBinding.select(
      session: saved,
      projectId: 'p',
      boardTaskId: 'T1',
    );
    final next = saved.observe(observed(1));
    for (final value in [
      saved,
      saved.requestCancellation(),
      AgentSession.fromJson({...next.toJson(), 'sessionId': 'another'}),
      AgentSession.fromJson({
        ...next.toJson(),
        'approval': {...next.approval.toJson(), 'content': 'changed'},
      }),
      saved.observe(observed(1)).observe(observed(2)),
    ]) {
      expect(
        () => binding.admitted(value, 'candidate-p-1:3'),
        throwsFormatException,
      );
    }
    expect(
      () => binding.admitted(next, 'candidate-p-2:3'),
      throwsFormatException,
    );
  });

  test(
    'admission cannot relabel prior references or change frozen membership',
    () {
      final original = session();
      final saved = AgentSession.fromJson({
        ...original.toJson(),
        'tasks': [task('T1'), task('T2')],
      });
      final first = AgentSessionBinding.select(
        session: saved,
        projectId: 'p',
        boardTaskId: 'T1',
      ).admitted(saved.observe(observed(1)), 'candidate-p-1:3');
      final next = first.session.observe(observed(2));
      final references = next.dispatches
          .map((value) => value.toJson())
          .toList();
      final changed = AgentSession.fromJson({
        ...next.toJson(),
        'dispatches': [
          {...references.first, 'boardTaskId': 'T2'},
          references.last,
        ],
      });
      expect(
        () => first.admitted(changed, 'candidate-p-2:3'),
        throwsFormatException,
      );
      final differentMembership = AgentSession.fromJson({
        ...next.toJson(),
        'tasks': [task('T1')],
      });
      expect(
        () => first.admitted(differentMembership, 'candidate-p-2:3'),
        throwsFormatException,
      );
    },
  );
}
