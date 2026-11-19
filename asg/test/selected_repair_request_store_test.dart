// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/models/repair_attempt.dart';
import 'package:asg/models/selected_repair_request.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/repair_attempt_store.dart';
import 'package:asg/services/repair_request_context.dart';
import 'package:asg/services/selected_repair_request_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'candidate_reopen_context_test.dart'
    show reopenFixture, reopenBefore, reopenAfter;
import 'candidate_repair_proposer_test.dart' show boundFailure, saveFailure;
import 'planning_conversation_test.dart' show project;
import 'selected_repair_request_test.dart' show selectedRepairFixture;
import 'source_candidate_controller_test.dart' show AtomicRecords;

void main() {
  test(
    'history bounds rendered project attempts without trimming saved budgets',
    () async {
      final f = await selectedRepairFixture();
      final records = AtomicRecords();
      final attempts = <RepairAttempt>[];
      for (var number = 1; number <= 35; number++) {
        final value =
            jsonDecode(jsonEncode(f.proposed.toJson())) as Map<String, dynamic>;
        value['number'] = number;
        final failure = value['failure'] as Map<String, dynamic>;
        final snapshot = failure['snapshot'] as Map<String, dynamic>;
        final approval = snapshot['approval'] as Map<String, dynamic>;
        approval['recordedAt'] = DateTime.utc(
          2026,
          1,
          number,
        ).toIso8601String();
        attempts.add(RepairAttempt.fromJson(value));
      }
      final key = 'studio.repairAttempts.v1.${project.id}';
      final raw = jsonEncode(RepairAttemptJournal(attempts).toJson());
      await records.setString(key, raw);
      final before = Map<String, String>.of(records.values);
      final history = SelectedRepairRequestStore(
        records,
        project.id,
      ).load(f.origin.requestSession.sessionId);
      expect(history.entries.length, 32);
      expect(history.omittedProjectAttempts, 3);
      expect(history.entries.first.attempt.number, 35);
      expect(history.entries.last.attempt.number, 4);
      expect(history.entries.every((e) => e.origin == null), isTrue);
      expect(
        RepairAttemptStore(records, project.id).load().attempts.length,
        35,
      );
      expect(records.values, before);
    },
  );

  for (final scenario in [
    'success',
    'occupied',
    'changed',
    'bad-input',
    'reserve-fails',
    'return-fails',
    'slot-race',
  ]) {
    test('selected origin atomic reservation and return: $scenario', () async {
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
      final run = CandidateVerificationJournal.fromJson(
        jsonDecode(
          f.records.getString('studio.candidateChecks.v1.${project.id}')!,
        ) as Map<String, dynamic>,
      ).runs.single;
      final context = RepairRequestContext.capture(
        records: f.records,
        project: project,
        failure: run,
        sessionBinding: AgentSessionBinding.select(
          session: f.session,
          projectId: project.id,
          boardTaskId: 'Tanalyze',
        ),
      );
      const model = ModelRequestProvenance(
        model: 'supplied-atomic-origin-model',
        outputTokens: 4096,
      );
      final capture = SelectedRepairRequestCapture(
        context: context,
        originals: {
          'lib/main.dart': scenario == 'bad-input'
              ? 'changed input'
              : reopenBefore,
        },
        modelRequest: model,
      );
      final store = RepairAttemptStore(f.records, project.id);
      final originKey = '${SelectedRepairRequest.prefix}${project.id}.1';
      if (scenario == 'occupied') {
        f.records.values[originKey] = 'retained foreign bytes';
      }
      if (scenario == 'reserve-fails') f.records.failCommit = true;
      if (scenario == 'slot-race') {
        f.records.beforeCommit = () async {
          f.records.values[originKey] = 'concurrent retained origin';
        };
      }
      final reserve = store.reserve(
        run,
        () {},
        modelRequest: model,
        context: context,
        selectedRequest: capture,
      );
      if ([
        'occupied',
        'bad-input',
        'reserve-fails',
        'slot-race',
      ].contains(scenario)) {
        await expectLater(reserve, throwsA(anything));
        expect(f.records.getString(store.key), isNull);
        expect(
          f.records.getString(originKey),
          scenario == 'occupied'
              ? 'retained foreign bytes'
              : scenario == 'slot-race'
              ? 'concurrent retained origin'
              : isNull,
        );
        expect(store.returnedReference, isNull);
        return;
      }
      await reserve;
      final raw = f.records.getString(originKey)!;
      final origin = SelectedRepairRequest.decode(raw);
      origin.requireAttempt(store.load().attempts.single);
      expect(store.returnedReference, isNull);
      if (scenario == 'changed') {
        f.records.values[originKey] = '$raw ';
      }
      if (scenario == 'return-fails') f.records.failCommit = true;
      final finish = store.finish(
        RepairAttemptStatus.proposed,
        authorizeReturn: () {},
        proposal: SourceEditProposal.parse(
          {
            'summary': 'Supplied replacement',
            'changes': [
              {
                'path': 'lib/main.dart',
                'before': reopenBefore,
                'after': reopenAfter,
              },
            ],
          },
          originals: {'lib/main.dart': reopenBefore},
          responseModel: 'supplied-observed-origin-model',
        ),
      );
      if (scenario == 'changed' || scenario == 'return-fails') {
        await expectLater(finish, throwsA(anything));
        expect(
          store.load().attempts.single.status,
          RepairAttemptStatus.reserved,
        );
        expect(store.returnedReference, isNull);
        expect(store.outcomeWriteAttempted, isTrue);
        f.records.failCommit = false;
        await expectLater(
          store.finish(RepairAttemptStatus.failed),
          throwsStateError,
        );
        expect(
          RepairAttemptStore(
            f.records,
            project.id,
          ).load().attempts.single.status,
          RepairAttemptStatus.reserved,
        );
      } else {
        await finish;
        store.returnedReference!.requireMatch(
          origin,
          store.load().attempts.single,
        );
        expect(f.records.getString(originKey), raw);
        final reader = SelectedRepairRequestStore(f.records, project.id);
        final page = reader.load(f.session.sessionId);
        expect(page.omittedProjectAttempts, 0);
        expect(page.entries.single.origin!.encode(), raw);
        expect(page.entries.single.reference, isNotNull);
        expect(reader.load('different-session').entries, isEmpty);
        // Current approval and working output do not authorize historical reads.
        f.records.values.remove('studio.generation.v1.${project.id}');
        f.records.values.remove(f.session.storageKey);
        expect(
          reader.load(f.session.sessionId).entries.single.origin,
          isNotNull,
        );
        f.records.values[originKey] = 'corrupt optional metadata';
        final bare = reader.load(f.session.sessionId).entries.single;
        expect(bare.origin, isNull);
        expect(bare.reference, isNull);
        expect(bare.attempt.status, RepairAttemptStatus.proposed);
        expect(store.load().attempts.length, 1);
      }
    });
  }
}
