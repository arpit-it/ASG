// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/repair_attempt.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/repair_attempt_store.dart';
import 'package:asg/services/source_edit_proposer.dart';
import 'package:asg/services/studio_database.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sembast/sembast_io.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'candidate_reopen_context_test.dart'
    show reopenFixture, reopenBefore, reopenAfter;
import 'candidate_repair_proposer_test.dart' show boundFailure, saveFailure;
import 'planning_conversation_test.dart' show project;
import 'source_edit_proposer_test.dart' show FakeProvider;

class SuppliedRepairContextProvider extends FakeProvider
    implements ModelResponseIdentityProvider {
  final entered = Completer<void>();
  @override
  String get completedResponseModel => 'supplied-repair-model';
  @override
  Stream<String> generate(String prompt) {
    entered.complete();
    return super.generate(prompt);
  }
}

String suppliedRepairResponse() => jsonEncode({
  'summary': 'Supplied repair context regression',
  'changes': [
    {'path': 'lib/main.dart', 'before': reopenBefore, 'after': reopenAfter},
  ],
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('selected repair captures explicit legacy working absence without creating a working record', () async {
    final f = await reopenFixture();
    final failed = GeneratedProject.fromJson({
      ...f.basis.sourceBase
          .copy(
            phase: SourceGenerationPhase.failed,
            checkpointVersion: 1,
            steps: boundFailure(f.records).steps,
            outputs: {},
          )
          .toJson(),
      'directory': '/supplied-failed-candidate',
    });
    await saveFailure(f.records, failed);
    final workingKey = 'studio.generation.v1.${project.id}';
    f.records.values.remove(workingKey);
    final provider = SuppliedRepairContextProvider();
    final service = ApprovedSourceProposer(
      f.records,
      proposer: SourceEditProposer(createProvider: (_) => provider),
    );
    final pending = service.propose(
      project: project,
      boardTaskId: 'Tanalyze',
      config: const LocalModelConfig(model: 'supplied-repair-model'),
      originals: const {'lib/main.dart': reopenBefore},
      repairCandidate: failed,
      repairSessionBinding: AgentSessionBinding.select(
        session: f.session,
        projectId: project.id,
        boardTaskId: 'Tanalyze',
      ),
    );
    await provider.entered.future;
    provider.stream.add(suppliedRepairResponse());
    unawaited(provider.stream.close());
    final evidence = await pending;
    expect(evidence.repairRun, isNotNull);
    expect(evidence.initialRequestOrigin, isNull);
    expect(f.records.getString(workingKey), isNull);
    expect(
      RepairAttemptStore(f.records, project.id).load().attempts.single.status,
      RepairAttemptStatus.proposed,
    );
  });
  for (final changed in [
    'approval',
    'failure',
    'candidate',
    'working',
    'session',
  ]) {
    for (final before in [true, false]) {
      test(
        'native $changed race ${before ? 'before reservation' : 'before return'} refuses durable stale repair',
        () async {
          final f = await reopenFixture();
          final failed = GeneratedProject.fromJson({
            ...f.basis.sourceBase
                .copy(
                  phase: SourceGenerationPhase.failed,
                  checkpointVersion: 1,
                  steps: boundFailure(f.records).steps,
                  outputs: {},
                )
                .toJson(),
            'directory': '/supplied-failed-candidate',
          });
          await saveFailure(f.records, failed);
          final root = await Directory.systemTemp.createTemp(
            'asg-repair-context-',
          );
          SharedPreferences.setMockInitialValues({});
          final prefs = await SharedPreferences.getInstance();
          var db = await databaseFactoryIo.openDatabase(
            '${root.path}/records.db',
          );
          try {
            final first = await StudioDatabase.migrate(db, prefs);
            for (final e in f.records.values.entries) {
              await first.setString(e.key, e.value);
            }
            final second = await StudioDatabase.migrate(db, prefs);
            final workingKey = 'studio.generation.v1.${project.id}';
            final originalWorking = first.getString(workingKey);
            final candidateKey = 'studio.sourceCandidate.v1.${project.id}';
            final journalKey = 'studio.candidateChecks.v1.${project.id}';
            Future<void> mutate() async {
              switch (changed) {
                case 'approval':
                  await PlanApprovalStore(second).save(
                    project,
                    ConversationStore(second).load(project.id),
                    false,
                  );
                case 'failure':
                  final journal = jsonDecode(
                    second.getString(journalKey)!,
                  ) as Map<String, dynamic>;
                  ((journal['runs'] as List).single as Map)['startedAt'] =
                      DateTime.utc(2025).toIso8601String();
                  await second.setString(journalKey, jsonEncode(journal));
                case 'candidate':
                  await second.setString(
                    candidateKey,
                    '${second.getString(candidateKey)} ',
                  );
                case 'working':
                  await second.setString(workingKey, '$originalWorking ');
                case 'session':
                  await AgentSessionStore(
                    second,
                    project,
                  ).requestCancellation(f.session);
              }
            }

            final provider = SuppliedRepairContextProvider();
            if (before) await mutate();
            final service = ApprovedSourceProposer(
              first,
              proposer: SourceEditProposer(createProvider: (_) => provider),
            );
            final pending = service.propose(
              project: project,
              boardTaskId: 'Tanalyze',
              config: const LocalModelConfig(model: 'supplied-repair-model'),
              originals: const {'lib/main.dart': reopenBefore},
              repairCandidate: failed,
              repairSessionBinding: AgentSessionBinding.select(
                session: f.session,
                projectId: project.id,
                boardTaskId: 'Tanalyze',
              ),
              repairWorkingRecord: originalWorking,
            );
            final rejection = expectLater(pending, throwsStateError);
            if (!before) {
              await provider.entered.future;
              expect(
                RepairAttemptStore(
                  first,
                  project.id,
                ).load().attempts.single.status,
                RepairAttemptStatus.reserved,
              );
              await mutate();
              provider.stream.add(suppliedRepairResponse());
              unawaited(provider.stream.close());
            }
            await rejection;
            expect(provider.prompt == null, before);
            await db.close();
            db = await databaseFactoryIo.openDatabase(
              '${root.path}/records.db',
            );
            final reopened = await StudioDatabase.migrate(db, prefs);
            final attempts = RepairAttemptStore(
              reopened,
              project.id,
            ).load().attempts;
            if (before) {
              expect(attempts, isEmpty);
            } else {
              expect(attempts.single.status, RepairAttemptStatus.reserved);
              expect(
                attempts.single.number,
                1,
              ); // Consumed after reopen; never refunded.
            }
            expect(
              reopened.getString(workingKey),
              changed == 'working' ? '$originalWorking ' : originalWorking,
            );
            expect(
              reopened.getString(
                'studio.agentExecution.v1.candidate-${project.id}-1',
              ),
              isNull,
            );
          } finally {
            await db.close();
            await root.delete(recursive: true);
          }
        },
      );
    }
  }
  test('failed proposed outcome has one write attempt and leaves the consumed reservation unresolved', () async {
    final f = await reopenFixture();
    final failed = GeneratedProject.fromJson({
      ...f.basis.sourceBase
          .copy(
            phase: SourceGenerationPhase.failed,
            checkpointVersion: 1,
            steps: boundFailure(f.records).steps,
            outputs: {},
          )
          .toJson(),
      'directory': '/supplied-failed-candidate',
    });
    await saveFailure(f.records, failed);
    var commits = 0;
    f.records.beforeCommit = () async {
      commits++;
      if (commits == 2) f.records.failCommit = true;
    };
    final provider = SuppliedRepairContextProvider();
    final service = ApprovedSourceProposer(
      f.records,
      proposer: SourceEditProposer(createProvider: (_) => provider),
    );
    final pending = service.propose(
      project: project,
      boardTaskId: 'Tanalyze',
      config: const LocalModelConfig(model: 'supplied-repair-model'),
      originals: const {'lib/main.dart': reopenBefore},
      repairCandidate: failed,
    );
    final rejection = expectLater(pending, throwsStateError);
    await provider.entered.future;
    final key = RepairAttemptStore(f.records, project.id).key;
    final reserved = f.records.getString(key);
    provider.stream.add(suppliedRepairResponse());
    unawaited(provider.stream.close());
    await rejection;
    expect(commits, 2); // No fallback failure/cancellation commit.
    expect(f.records.getString(key), reserved);
    final reopened = RepairAttemptStore(f.records, project.id);
    expect(
      reopened.load().attempts.single.status,
      RepairAttemptStatus.reserved,
    );
    f.records.failCommit = false;
    f.records.beforeCommit = null;
    final run = CandidateVerificationJournal.fromJson(
      jsonDecode(
        f.records.getString('studio.candidateChecks.v1.${project.id}')!,
      ) as Map<String, dynamic>,
    ).runs.single;
    await reopened.reserve(run, () {});
    expect(reopened.load().attempts.map((a) => a.number), [1, 2]);
  });
}
