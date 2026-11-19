// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/agent_task_decision.dart';
import 'package:asg/services/agent_task_decision_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'planning_conversation_test.dart' show project;
import 'published_task_evidence_store_test.dart' show evidenceFixture;

void main() {
  test(
    'strict canonical immutable decision and frozen proof round trip',
    () async {
      final f = await evidenceFixture(
        allAuthoredRules: true,
        taskId: 'Tresolve',
      );
      final evidence = AgentTaskDecisionStore(
        f.records,
        project,
      ).select(f.session, f.run.number).evidence;
      final decision = AgentTaskDecision.confirm(
        evidence,
        DateTime.utc(2026, 11, 19),
        consent: true,
      );
      final raw = jsonEncode(decision.toJson());
      expect(jsonEncode(AgentTaskDecision.decode(raw).toJson()), raw);
      expect(
        () => AgentTaskDecision.confirm(
          evidence,
          DateTime.utc(2026),
          consent: false,
        ),
        throwsFormatException,
      );
      final copy = decision.toJson();
      (copy['evidence'] as Map)['requirement'] = null;
      expect(jsonEncode(decision.toJson()), raw);
      expect(() => evidence.observations.clear(), throwsUnsupportedError);
      expect(
        () => AgentTaskDecisionStore.decode('${decision.storageKey}other', raw),
        throwsFormatException,
      );
      expect(
        () => AgentTaskDecision.decode('{"version":1,$raw'),
        throwsFormatException,
      );
      expect(
        () => AgentTaskDecision.decode(
          ' ' * (AgentTaskDecision.maxEncodedBytes + 1),
        ),
        throwsFormatException,
      );
    },
  );

  test('foreign, malformed and contradictory frozen proof cannot claim authored-check completion', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final evidence = AgentTaskDecisionStore(
      f.records,
      project,
    ).select(f.session, f.run.number).evidence;
    final good = AgentTaskDecision.confirm(
      evidence,
      DateTime.utc(2026),
      consent: true,
    );
    final mutations = <void Function(Map<String, dynamic>)>[
      (v) => v['extra'] = true,
      (v) => v['version'] = 1.0,
      (v) => v['mode'] = 'completed',
      (v) => v['confirmedAt'] = '2026-01-01',
      (v) => (v['evidence'] as Map)['extra'] = true,
      (v) => ((v['evidence'] as Map)['requirement'] as Map)['id'] = 'Foreign',
      (v) => ((v['evidence'] as Map)['requirement'] as Map)['criteria'] = [],
      (v) =>
          ((((v['evidence'] as Map)['requirement'] as Map)['criteria'] as List)
                      .first
                  as Map)['verificationRule'] =
              'none',
      (v) => ((v['evidence'] as Map)['identity'] as Map)['savedRunSha256'] =
          'a' * 64,
      (v) => ((v['evidence'] as Map)['identity'] as Map)['currentInputSha256'] =
          'b' * 64,
      (v) => ((v['evidence'] as Map)['identity'] as Map)['schema'] = 2,
      (v) => ((v['evidence'] as Map)['identity'] as Map)['schema'] = 1.0,
      (v) => ((v['evidence'] as Map)['observations'] as List).clear(),
      (v) =>
          ((((v['evidence'] as Map)['observations'] as List).first
                      as Map)['result']
                  as Map)['cancelled'] =
              true,
      (v) =>
          (((v['evidence'] as Map)['observations'] as List).first
                  as Map)['requirementSha256'] =
              'c' * 64,
      (v) =>
          (((v['evidence'] as Map)['observations'] as List).first
                  as Map)['checkId'] =
              'Foreign',
      (v) => ((v['evidence'] as Map)['prerequisites'] as List).add({
        'taskId': 'Tanalyze',
        'runNumber': 1,
        'sha256': 'a' * 64,
      }),
    ];
    for (var i = 0; i < mutations.length; i++) {
      final value = good.toJson();
      mutations[i](value);
      expect(
        () => AgentTaskDecision.fromJson(value),
        throwsFormatException,
        reason: 'mutation $i',
      );
    }
  });
}
