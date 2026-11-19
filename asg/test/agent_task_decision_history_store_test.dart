// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/services/agent_task_decision_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/agent_session_run_status_store.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/models/agent_session_run_status.dart';
import 'package:flutter_test/flutter_test.dart';

import 'planning_conversation_test.dart' show project;
import 'agent_task_decision_store_test.dart' show dependentPublication;
import 'published_task_evidence_store_test.dart' show evidenceFixture;

final class ReadOnlyHistory implements RecordStorage {
  ReadOnlyHistory(this.source, {this.afterRead});
  final RecordStorage source;
  final void Function(String)? afterRead;
  int writes = 0;
  @override
  String? getString(String key) {
    final value = source.getString(key);
    afterRead?.call(key);
    return value;
  }

  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    throw StateError('Read-only fixture.');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('multiple publications of one task retain separate exact decisions through growth and withdrawal', () async {
    final first = await evidenceFixture(
      allAuthoredRules: true,
      taskId: 'Tresolve',
    );
    final writer = AgentTaskDecisionStore(first.records, project);
    final one = await writer.confirm(
      writer.select(first.session, first.run.number),
      consent: true,
      authorized: () => true,
    );
    final second = await dependentPublication(first, taskId: 'Tresolve');
    final two = await writer.confirm(
      writer.select(second.session, second.run.number),
      consent: true,
      authorized: () => true,
    );
    expect(two.fingerprint, isNot(one.fingerprint));
    final withdrawn = await AgentSessionStore(
      first.records,
      project,
    ).requestCancellation(second.session);
    first.records.values.remove('studio.planApproval.v1.${project.id}');
    first.records.values['studio.generation.v1.${project.id}'] = '{}';
    final before = Map.of(first.records.values);
    final history = AgentTaskDecisionHistoryStore(first.records, project.id);
    expect(
      history.load(withdrawn, first.run.number)?.fingerprint,
      one.fingerprint,
    );
    expect(
      history.load(withdrawn, second.run.number)?.fingerprint,
      two.fingerprint,
    );
    final statuses = AgentSessionRunStatusStore(
      first.records,
      project.id,
    ).load(withdrawn);
    expect(
      statuses.map((s) => s.reference.runNumber),
      withdrawn.dispatches.map((r) => r.runNumber),
    );
    for (final n in [first.run.number, second.run.number]) {
      final status = statuses.singleWhere((s) => s.reference.runNumber == n);
      expect(status.decisionState, AgentSessionDecisionState.recorded);
      expect(status.reference.boardTaskId, 'Tresolve');
      expect(status.publication, isNotNull);
    }
    expect(first.records.values, before);
  });

  test('historical reader needs only project ID and never writes', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final writer = AgentTaskDecisionStore(f.records, project);
    final saved = await writer.confirm(
      writer.select(f.session, f.run.number),
      consent: true,
      authorized: () => true,
    );
    final records = ReadOnlyHistory(f.records);
    final before = Map.of(f.records.values);
    final retained = AgentTaskDecisionHistoryStore(
      records,
      project.id,
    ).load(f.session, f.run.number);
    expect(retained?.fingerprint, saved.fingerprint);
    expect(f.records.values, before);
    expect(records.writes, 0);
    expect(
      () => AgentTaskDecisionHistoryStore(
        records,
        'foreign',
      ).load(f.session, f.run.number),
      throwsFormatException,
    );
  });

  test(
    'absence requires the exact saved session and retained reference',
    () async {
      final f = await evidenceFixture(
        allAuthoredRules: true,
        taskId: 'Tresolve',
      );
      final before = Map.of(f.records.values);
      final reader = AgentTaskDecisionHistoryStore(f.records, project.id);
      expect(reader.load(f.session, f.run.number), isNull);
      expect(
        () => reader.load(f.session, f.run.number + 100),
        throwsFormatException,
      );
      f.records.values.remove(f.session.storageKey);
      expect(() => reader.load(f.session, f.run.number), throwsFormatException);
      f.records.values.addAll(before);
      f.records.values[f.session.storageKey] = '{}';
      expect(() => reader.load(f.session, f.run.number), throwsFormatException);
    },
  );

  test('changed session during an absent read fails closed', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final records = ReadOnlyHistory(
      f.records,
      afterRead: (key) {
        if (key.startsWith('studio.agentTaskDecision.')) {
          f.records.values[f.session.storageKey] = '{}';
        }
      },
    );
    expect(
      () => AgentTaskDecisionHistoryStore(
        records,
        project.id,
      ).load(f.session, f.run.number),
      throwsStateError,
    );
    expect(records.writes, 0);
  });
}
