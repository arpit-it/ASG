// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:asg/services/studio_database.dart';

import 'package:asg/models/agent_session.dart';
import 'package:asg/models/agent_task_decision.dart';
import 'package:asg/models/candidate_reopen_context.dart';
import 'package:asg/models/prerequisite_preparation_evidence.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/agent_task_decision_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_task_decision_history_store_test.dart' show ReadOnlyHistory;
import 'agent_task_decision_store_test.dart' show dependentPublication;
import 'candidate_reopen_context_test.dart' show reopenHash, reopenAfter;
import 'planning_conversation_test.dart' show project;
import 'published_task_evidence_store_test.dart'
    show evidenceFixture, EvidenceFixture;

typedef PreparationFixture = ({
  EvidenceFixture next,
  AgentTaskDecision prior,
  AgentTaskDecision dependent,
});
Future<PreparationFixture> preparationFixture() async {
  final first = await evidenceFixture(
    allAuthoredRules: true,
    taskId: 'Tresolve',
  );
  final writer = AgentTaskDecisionStore(first.records, project);
  final prior = await writer.confirm(
    writer.select(first.session, first.run.number),
    consent: true,
    authorized: () => true,
  );
  final next = await dependentPublication(first);
  final dependent = await writer.confirm(
    writer.select(
      next.session,
      next.run.number,
      prerequisites: {'Tresolve': first.run.number},
    ),
    consent: true,
    authorized: () => true,
  );
  return (next: next, prior: prior, dependent: dependent);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('exact retained edge is directly linked, detached and read-only after withdrawal/current rotation', () async {
    final f = await preparationFixture();
    final session = await AgentSessionStore(
      f.next.records,
      project,
    ).requestCancellation(f.next.session);
    f.next.records.values['studio.generation.v1.${project.id}'] = '{}';
    f.next.records.values.remove('studio.planApproval.v1.${project.id}');
    final before = Map.of(f.next.records.values);
    final reads = ReadOnlyHistory(f.next.records);
    final review = AgentPrerequisitePreparationStore(
      reads,
      project.id,
    ).load(session, f.next.run.number)!;
    expect(review.decisionSha256, f.dependent.fingerprint);
    expect(review.prerequisites.single.reference.sha256, f.prior.fingerprint);
    expect(
      review.prerequisites.single.state,
      PrerequisitePreparationState.directRecordedLink,
    );
    expect(() => review.prerequisites.clear(), throwsUnsupportedError);
    expect(f.next.records.values, before);
    expect(reads.writes, 0);
  });

  test('valid divergent reviewed source base is no direct match despite identical working hash', () async {
    final f = await preparationFixture();
    final key =
        '${CandidateReopenContext.prefix}${project.id}.${f.next.run.number}';
    final context = jsonDecode(f.next.records.values[key]!);
    const alternate = 'void main() { /* another reviewed base */ }';
    context['basis']['sourceBase']['sources']['lib/main.dart'] = reopenHash(
      alternate,
    );
    context['basis']['evidence']['proposal']['changes'][0]['before'] =
        alternate;
    f.next.records.values[key] = jsonEncode(context);
    final before = Map.of(f.next.records.values);
    final review = AgentPrerequisitePreparationStore(
      f.next.records,
      project.id,
    ).load(f.next.session, f.next.run.number)!;
    expect(
      review.prerequisites.single.state,
      PrerequisitePreparationState.noDirectMatch,
    );
    expect(
      AgentTaskDecisionStore(
        f.next.records,
        project,
      ).load(f.next.session, f.next.run.number)?.fingerprint,
      f.dependent.fingerprint,
    );
    expect(f.next.records.values, before);
  });

  test('missing malformed noncanonical or foreign preparation preserves the valid decision as unavailable', () async {
    final f = await preparationFixture();
    final key =
        '${CandidateReopenContext.prefix}${project.id}.${f.next.run.number}';
    final original = f.next.records.values[key]!;
    final foreign = jsonDecode(original)..['runNumber'] = 99;
    for (final raw in [
      null,
      '{private bad bytes',
      ' $original',
      jsonEncode(foreign),
    ]) {
      if (raw == null) {
        f.next.records.values.remove(key);
      } else {
        f.next.records.values[key] = raw;
      }
      final before = Map.of(f.next.records.values);
      final review = AgentPrerequisitePreparationStore(
        f.next.records,
        project.id,
      ).load(f.next.session, f.next.run.number)!;
      expect(
        review.prerequisites.single.state,
        PrerequisitePreparationState.unavailable,
      );
      expect(review.decisionSha256, f.dependent.fingerprint);
      expect(f.next.records.values, before);
    }
  });

  test(
    'later publication does not retarget the exact retained prerequisite edge',
    () async {
      final f = await preparationFixture();
      final grown = await dependentPublication(
        f.next,
        taskId: 'Tresolve',
        directory: '/later-candidate',
        beforeText: '$reopenAfter\n// dependent reviewed candidate',
      );
      final before = Map.of(f.next.records.values);
      final review = AgentPrerequisitePreparationStore(
        f.next.records,
        project.id,
      ).load(grown.session, f.next.run.number)!;
      expect(
        review.prerequisites.single.reference.runNumber,
        f.prior.evidence.publication.runNumber,
      );
      expect(
        review.prerequisites.single.reference.runNumber,
        isNot(grown.run.number),
      );
      expect(
        review.prerequisites.single.state,
        PrerequisitePreparationState.directRecordedLink,
      );
      expect(f.next.records.values, before);
    },
  );

  test('valid typed working mismatch cannot inherit a direct link from digest fields', () async {
    final f = await preparationFixture();
    final key =
        '${CandidateReopenContext.prefix}${project.id}.${f.next.run.number}';
    final value = jsonDecode(f.next.records.values[key]!);
    value['basis']['working']['sources']['lib/main.dart'] = 'c' * 64;
    f.next.records.values[key] = jsonEncode(value);
    final before = Map.of(f.next.records.values);
    final review = AgentPrerequisitePreparationStore(
      f.next.records,
      project.id,
    ).load(f.next.session, f.next.run.number)!;
    expect(
      review.prerequisites.single.state,
      PrerequisitePreparationState.noDirectMatch,
    );
    expect(f.next.records.values, before);
  });

  test('two prerequisite edges retain independent direct and non-direct preparation facts', () async {
    final root = await evidenceFixture(
      allAuthoredRules: true,
      taskId: 'Tresolve',
    );
    final writer = AgentTaskDecisionStore(root.records, project);
    await writer.confirm(
      writer.select(root.session, root.run.number),
      consent: true,
      authorized: () => true,
    );
    final tests = await dependentPublication(root, taskId: 'Ttest');
    await writer.confirm(
      writer.select(
        tests.session,
        tests.run.number,
        prerequisites: {'Tresolve': root.run.number},
      ),
      consent: true,
      authorized: () => true,
    );
    const firstText = '$reopenAfter\n// dependent reviewed candidate';
    final analysis = await dependentPublication(
      tests,
      taskId: 'Tanalyze',
      beforeText: firstText,
      directory: '/analysis-candidate',
    );
    await writer.confirm(
      writer.select(
        analysis.session,
        analysis.run.number,
        prerequisites: {'Tresolve': root.run.number},
      ),
      consent: true,
      authorized: () => true,
    );
    final build = await dependentPublication(
      analysis,
      taskId: 'Tbuild',
      beforeText: '$firstText\n// dependent reviewed candidate',
      directory: '/build-candidate',
    );
    await writer.confirm(
      writer.select(
        build.session,
        build.run.number,
        prerequisites: {
          'Ttest': tests.run.number,
          'Tanalyze': analysis.run.number,
        },
      ),
      consent: true,
      authorized: () => true,
    );
    final before = Map.of(root.records.values);
    final review = AgentPrerequisitePreparationStore(
      root.records,
      project.id,
    ).load(build.session, build.run.number)!;
    expect(review.prerequisites, hasLength(2));
    expect(
      review.prerequisites
          .singleWhere((e) => e.reference.taskId == 'Ttest')
          .state,
      PrerequisitePreparationState.noDirectMatch,
    );
    expect(
      review.prerequisites
          .singleWhere((e) => e.reference.taskId == 'Tanalyze')
          .state,
      PrerequisitePreparationState.directRecordedLink,
    );
    expect(root.records.values, before);
  });

  test('actual native database close and reopen retains exact read-only preparation evidence', () async {
    final f = await preparationFixture();
    final temp = await Directory.systemTemp.createTemp(
      'asg-preparation-reopen-',
    );
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final path = '${temp.path}/records.db';
    var db = await databaseFactoryIo.openDatabase(path);
    try {
      var records = await StudioDatabase.migrate(db, prefs);
      for (final e in f.next.records.values.entries) {
        await records.setString(e.key, e.value);
      }
      final before = {
        for (final e in f.next.records.values.entries)
          e.key: records.getString(e.key),
      };
      await db.close();
      db = await databaseFactoryIo.openDatabase(path);
      records = await StudioDatabase.migrate(db, prefs);
      final review = AgentPrerequisitePreparationStore(
        records,
        project.id,
      ).load(f.next.session, f.next.run.number)!;
      expect(review.decisionSha256, f.dependent.fingerprint);
      expect(review.prerequisites.single.reference.sha256, f.prior.fingerprint);
      expect(
        review.prerequisites.single.state,
        PrerequisitePreparationState.directRecordedLink,
      );
      expect({
        for (final e in before.entries) e.key: records.getString(e.key),
      }, before);
    } finally {
      await db.close();
      await temp.delete(recursive: true);
    }
  });

  test('composed read race refuses a mixed snapshot without writing', () async {
    final f = await preparationFixture();
    final reads = ReadOnlyHistory(
      f.next.records,
      afterRead: (key) {
        if (key.startsWith(CandidateReopenContext.prefix)) {
          f.next.records.values[f.next.session.storageKey] = '{}';
        }
      },
    );
    expect(
      () => AgentPrerequisitePreparationStore(
        reads,
        project.id,
      ).load(f.next.session, f.next.run.number),
      throwsStateError,
    );
    expect(reads.writes, 0);
  });

  test('root decision needs no optional candidate context; absent decision is not backfilled', () async {
    final f = await evidenceFixture(allAuthoredRules: true, taskId: 'Tresolve');
    final reader = AgentPrerequisitePreparationStore(f.records, project.id);
    final before = Map.of(f.records.values);
    expect(reader.load(f.session, f.run.number), isNull);
    expect(f.records.values, before);
    final writer = AgentTaskDecisionStore(f.records, project);
    await writer.confirm(
      writer.select(f.session, f.run.number),
      consent: true,
      authorized: () => true,
    );
    f.records.values.remove(
      '${CandidateReopenContext.prefix}${project.id}.${f.run.number}',
    );
    expect(reader.load(f.session, f.run.number)!.prerequisites, isEmpty);
    expect(
      () => reader.load(
        AgentSession.fromJson({...f.session.toJson(), 'projectId': 'foreign'}),
        f.run.number,
      ),
      throwsA(anything),
    );
  });
}
