// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/controllers/saved_candidate_recovery_controller.dart';
import 'package:asg/models/agent_session.dart';
import 'package:asg/models/agent_session_publication.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'candidate_reopen_context_test.dart' show ReopenFixture;
import 'planning_conversation_test.dart' show project;
import 'saved_candidate_recovery_controller_test.dart'
    show admittedReopen, ReopenInspectionHost;

typedef PublishedFixture = ({
  ReopenFixture fixture,
  AgentSession session,
  CandidateVerificationRun run,
  AgentSessionPublication publication,
  String originalWorking,
});

Future<PublishedFixture> publishedFixture() async {
  final a = await admittedReopen();
  final f = a.fixture;
  final c = SavedCandidateRecoveryController(
    project: project,
    records: f.records,
    selectedSession: a.journal.admittedSession!,
    runNumber: 1,
    createHost: ReopenInspectionHost.new,
  );
  await c.open();
  expect(c.error, isNull);
  final original = f.records.getString('studio.generation.v1.${project.id}')!;
  final candidate = c.candidate!;
  await candidate.verify(approved: true);
  expect(candidate.error, isNull);
  expect(await candidate.promote(approved: true), isTrue);
  final run = CandidateVerificationStore(
    f.records,
    project.id,
  ).load().runs.last;
  final publication = AgentSessionPublication.decode(
    f.records.getString(
      '${AgentSessionPublication.prefix}${project.id}.${run.number}',
    )!,
  );
  final result = (
    fixture: f,
    session: candidate.sessionBinding!.session,
    run: run,
    publication: publication,
    originalWorking: original,
  );
  c.dispose();
  return result;
}

void main() {
  test('publication retains exact run, session and promotion transition defensively', () async {
    final f = await publishedFixture(), p = f.publication;
    p.requireRun(f.run);
    p.requireSession(f.session);
    p.requireSession(f.session.requestCancellation());
    expect(
      AgentSessionPublication.decode(jsonEncode(p.toJson())).toJson(),
      p.toJson(),
    );
    final altered = p.toJson();
    (altered['session'] as Map)['sessionId'] = 'changed';
    expect(p.session.sessionId, f.session.sessionId);
    expect(p.reference.boardTaskId, 'Tanalyze');
    expect(p.executionAfter.phase.name, 'completed');
    expect(p.originalWorkingSha256, isNot(p.publishedWorkingSha256));
  });

  test('strict publication schema and transition identity reject altered and oversized records', () async {
    final f = await publishedFixture();
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (v) => v['unexpected'] = true,
      (v) => v['version'] = true,
      (v) => v['runNumber'] = 1,
      (v) => v['dispatchId'] = 'other:3',
      (v) => v['runStartedAt'] = '2026-01-01T00:00:00+00:00',
      (v) => v['verifiedRunSha256'] = 'bad',
      (v) => v['publishedWorkingSha256'] = v['originalWorkingSha256'],
      (v) => (v['executionBefore'] as Map)['phase'] = 'executing',
      (v) => (v['executionAfter'] as Map)['revision'] = 99,
      (v) => (v['executionAfter'] as Map)['taskId'] = 'foreign',
      (v) => (v['session'] as Map)['cancellationRequested'] = true,
    ]) {
      final data = f.publication.toJson();
      mutate(data);
      expect(
        () => AgentSessionPublication.fromJson(data),
        throwsFormatException,
      );
    }
    final raw = jsonEncode(f.publication.toJson());
    expect(
      () => AgentSessionPublication.decode(
        raw.replaceFirst('{', '{"version":1,'),
      ),
      throwsFormatException,
    );
    expect(
      () => AgentSessionPublication.decode(
        ' ' * (AgentSessionPublication.maxEncodedBytes + 1),
      ),
      throwsFormatException,
    );
  });

  test(
    'publication cannot be rebound to a changed run or foreign session',
    () async {
      final f = await publishedFixture();
      final changed = CandidateVerificationRun.fromJson({
        ...f.run.toJson(),
        'startedAt': DateTime.utc(2025).toIso8601String(),
      });
      expect(() => f.publication.requireRun(changed), throwsFormatException);
      final foreign = AgentSession.fromJson({
        ...f.session.toJson(),
        'sessionId': 'foreign',
      });
      expect(
        () => f.publication.requireSession(foreign),
        throwsFormatException,
      );
    },
  );
}
