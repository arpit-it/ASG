// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';
import 'dart:io';

import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/candidate_reopen_context.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_admission.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/candidate_reopen_context_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'candidate_reopen_context_test.dart' show ReopenFixture, reopenFixture;
import 'planning_conversation_test.dart' show project;

Future<CandidateVerificationRun> startReopen(
  ReopenFixture f,
  CandidateVerificationStore journal, {
  ConditionalRecordStorage? records,
}) => journal.start(
  f.basis.prepared.copy(phase: SourceGenerationPhase.verifying),
  () {},
  reopenBasis: f.basis,
  sessionAdmission: AgentSessionRunAdmission(
    records ?? f.records,
    project,
    AgentSessionBinding.select(
      session: f.session,
      projectId: project.id,
      boardTaskId: 'Tanalyze',
    ),
  ),
);

void main() {
  test('admission publishes context jointly and latest loader reads without mutation', () async {
    final f = await reopenFixture();
    final journal = CandidateVerificationStore(f.records, project.id);
    final run = await startReopen(f, journal);
    final session = journal.admittedSession!;
    final before = Map.of(f.records.values);
    final store = CandidateReopenContextStore(f.records, project);
    final context = store.loadLatest(session, run.number);
    context.requireRun(run);
    expect(
      context.basis.evidence.proposal.changes.single.after,
      contains('reviewed'),
    );
    expect(f.records.values, before);
    store.requireUnchanged(context);
    expect(f.records.values, before);
    final raw = f.records.getString(context.storageKey)!;
    expect(
      () => StudioDatabase.validate(
        '${CandidateReopenContext.prefix}foreign.1',
        raw,
      ),
      throwsFormatException,
    );
    expect(
      () => StudioDatabase.validate(context.storageKey, '{private malformed'),
      throwsFormatException,
    );
    expect(f.records.getString(context.storageKey), raw);
  });

  test('failed startup and original-working race publish no partial context or run', () async {
    for (final race in [false, true]) {
      final f = await reopenFixture();
      final before = Map.of(f.records.values);
      if (race) {
        f.records.beforeCommit = () async {
          f.records.beforeCommit = null;
          f.records.values['studio.generation.v1.${project.id}'] =
              '${before['studio.generation.v1.${project.id}']} ';
        };
      } else {
        f.records.failCommit = true;
      }
      await expectLater(
        startReopen(f, CandidateVerificationStore(f.records, project.id)),
        throwsStateError,
      );
      if (race) {
        expect(
          Map.of(f.records.values)
            ..remove('studio.generation.v1.${project.id}'),
          Map.of(before)..remove('studio.generation.v1.${project.id}'),
        );
      } else {
        expect(f.records.values, before);
      }
      expect(
        f.records.getString('${CandidateReopenContext.prefix}${project.id}.1'),
        isNull,
      );
      expect(
        f.records.getString('studio.candidateChecks.v1.${project.id}'),
        isNull,
      );
    }
  });

  test('pending checkpoint and explicit acknowledgment never rewrite context', () async {
    final f = await reopenFixture();
    final journal = CandidateVerificationStore(f.records, project.id);
    final run = await startReopen(f, journal);
    final key = '${CandidateReopenContext.prefix}${project.id}.1';
    final contextRaw = f.records.getString(key);
    await journal.checkpoint(
      run.snapshot.copy(pendingOperation: 'resolve'),
      () {},
    );
    final pending = journal.load().runs.single;
    expect(f.records.getString(key), contextRaw);
    // Supplied operator confirmation only; no actual command or cleanup claim.
    await CandidateVerificationStore(
      f.records,
      project.id,
    ).acknowledgeStopped(pending, () {});
    final after = Map.of(f.records.values);
    final context = CandidateReopenContextStore(
      f.records,
      project,
    ).loadLatest(journal.admittedSession!, 1);
    expect(context.storageKey, key);
    expect(f.records.getString(key), contextRaw);
    expect(f.records.values, after);
  });

  test('superseded immutable context refuses checkpoint and acknowledgment without rewriting it', () async {
    final f = await reopenFixture();
    final journal = CandidateVerificationStore(f.records, project.id);
    final run = await startReopen(f, journal);
    await journal.checkpoint(
      run.snapshot.copy(pendingOperation: 'resolve'),
      () {},
    );
    final pending = journal.load().runs.single;
    final key = '${CandidateReopenContext.prefix}${project.id}.1';
    f.records.values[key] = '{retained damaged context';
    final before = Map.of(f.records.values);
    await expectLater(
      journal.checkpoint(
        pending.snapshot.copy(phase: SourceGenerationPhase.failed),
        () {},
      ),
      throwsStateError,
    );
    await expectLater(
      CandidateVerificationStore(
        f.records,
        project.id,
      ).acknowledgeStopped(pending, () {}),
      throwsFormatException,
    );
    expect(f.records.values, before);
  });

  test('loader refuses missing/foreign/context/working/cancellation changes and preserves bytes', () async {
    for (final change in [
      'missing',
      'foreign',
      'working',
      'cancelled',
      'candidate',
      'history',
    ]) {
      final f = await reopenFixture();
      final journal = CandidateVerificationStore(f.records, project.id);
      await startReopen(f, journal);
      final session = journal.admittedSession!;
      final key = '${CandidateReopenContext.prefix}${project.id}.1';
      if (change == 'missing') f.records.values.remove(key);
      if (change == 'foreign') {
        final value =
            jsonDecode(f.records.getString(key)!) as Map<String, dynamic>;
        (value['basis'] as Map)['projectId'] = 'foreign';
        f.records.values[key] = jsonEncode(value);
      }
      if (change == 'working') {
        f.records.values['studio.generation.v1.${project.id}'] =
            '${f.records.values['studio.generation.v1.${project.id}']} ';
      }
      if (change == 'cancelled') {
        await AgentSessionStore(
          f.records,
          project,
        ).requestCancellation(session);
      }
      if (change == 'candidate') {
        f.records.values[journal.candidateKey] =
            '${f.records.values[journal.candidateKey]} ';
      }
      if (change == 'history') {
        f.records.values['studio.agentTaskHistory.v1.${project.id}.1'] =
            '{unreadable';
      }
      final before = Map.of(f.records.values);
      expect(
        () => CandidateReopenContextStore(
          f.records,
          project,
        ).loadLatest(session, 1),
        throwsFormatException,
      );
      expect(f.records.values, before);
    }
  });

  test('actual native database close/reopen retains admitted context and read-only projection', () async {
    final f = await reopenFixture();
    final root = await Directory.systemTemp.createTemp('asg-reopen-context-');
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    var db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
    try {
      var native = await StudioDatabase.migrate(db, preferences);
      for (final entry in f.records.values.entries) {
        await native.setString(entry.key, entry.value);
      }
      final journal = CandidateVerificationStore(native, project.id);
      final run = await startReopen(f, journal, records: native);
      final session = journal.admittedSession!;
      final key = '${CandidateReopenContext.prefix}${project.id}.1';
      final before = native.getString(key);
      await db.close();
      db = await databaseFactoryIo.openDatabase('${root.path}/records.db');
      native = await StudioDatabase.migrate(db, preferences);
      final context = CandidateReopenContextStore(
        native,
        project,
      ).loadLatest(session, run.number);
      expect(jsonEncode(context.toJson()), before);
      expect(native.getString(key), before);
    } finally {
      await db.close();
      await root.delete(recursive: true);
    }
  });
}
