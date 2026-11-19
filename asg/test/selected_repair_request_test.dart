// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/agent_session.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/models/repair_attempt.dart';
import 'package:asg/models/selected_repair_request.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/repair_attempt_store.dart';
import 'package:asg/services/repair_request_context.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'candidate_reopen_context_test.dart'
    show reopenFixture, reopenBefore, reopenAfter;
import 'candidate_repair_proposer_test.dart' show boundFailure, saveFailure;
import 'planning_conversation_test.dart' show project;

typedef SelectedRepairFixture = ({
  SelectedRepairRequest origin,
  RepairAttempt reserved,
  RepairAttempt proposed,
});
Future<SelectedRepairFixture> selectedRepairFixture({
  bool formatted = false,
}) async {
  final f = await reopenFixture();
  final sessionRaw = formatted
      ? const JsonEncoder.withIndent('  ').convert(f.session.toJson())
      : jsonEncode(f.session.toJson());
  f.records.values[f.session.storageKey] = sessionRaw;
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
    jsonDecode(f.records.getString('studio.candidateChecks.v1.${project.id}')!)
        as Map<String, dynamic>,
  ).runs.single;
  const settings = ModelRequestProvenance(
    model: 'supplied-origin-model',
    outputTokens: 4096,
  );
  final store = RepairAttemptStore(f.records, project.id);
  await store.reserve(
    run,
    () {},
    modelRequest: settings,
    context: RepairRequestContext.capture(
      records: f.records,
      project: project,
      failure: run,
      sessionBinding: AgentSessionBinding.select(
        session: f.session,
        projectId: project.id,
        boardTaskId: 'Tanalyze',
      ),
    ),
  );
  final reserved = store.load().attempts.single;
  final origin = SelectedRepairRequest(
    projectId: project.id,
    attemptNumber: reserved.number,
    boardTaskId: 'Tanalyze',
    requirementId: f.session.tasks.items
        .singleWhere((t) => t.id == 'Tanalyze')
        .requirementId,
    requirementsRevision: RequirementsStore(f.records)
        .load(project.id)
        .revision,
    reservationSha256: SelectedRepairRequest.fingerprint(
      jsonEncode(reserved.toJson()),
    ),
    failedRunSha256: SelectedRepairRequest.fingerprint(
      jsonEncode(run.toJson()),
    ),
    workingSha256: SelectedRepairRequest.fingerprint(
      f.records.getString('studio.generation.v1.${project.id}')!,
    ),
    requestSessionRecord: sessionRaw,
    sourceSha256: {'lib/main.dart': failed.sources['lib/main.dart']!},
    modelRequest: settings,
  );
  final proposal = SourceEditProposal.parse(
    {
      'summary': 'Supplied model proof',
      'changes': [
        {'path': 'lib/main.dart', 'before': reopenBefore, 'after': reopenAfter},
      ],
    },
    originals: const {'lib/main.dart': reopenBefore},
    responseModel: settings.model,
  );
  await store.finish(
    RepairAttemptStatus.proposed,
    proposal: proposal,
    authorizeReturn: () {},
  );
  expect(
    f.records.getString(origin.storageKey),
    isNull,
  ); // Pure foundation, not a persisted origin yet.
  return (
    origin: origin,
    reserved: reserved,
    proposed: store.load().attempts.single,
  );
}

void main() {
  test('malformed JSON errors do not expose retained private bytes', () {
    const raw = '{"private":"private-token","unfinished":';
    for (final decode in [
      SelectedRepairRequest.decode,
      SelectedRepairRequestReference.decode,
    ]) {
      try {
        decode(raw);
        fail('Expected invalid JSON');
      } on FormatException catch (error) {
        expect(error.source, isNull);
        expect('$error', isNot(contains('private-token')));
      }
    }
  });

  test('canonical origin/reference preserve raw bytes and bind requested to observed versions', () async {
    final f = await selectedRepairFixture(formatted: true);
    final origin = SelectedRepairRequest.decode(f.origin.encode());
    origin.requireAttempt(f.reserved);
    origin.requireAttempt(f.proposed);
    expect(origin.requestSessionRecord, f.origin.requestSessionRecord);
    expect(origin.requestSessionRecord, contains('\n'));
    expect(
      SelectedRepairRequest.fingerprint(origin.requestSessionRecord),
      isNot(
        SelectedRepairRequest.fingerprint(
          jsonEncode(origin.requestSession.toJson()),
        ),
      ),
    );
    expect(origin.modelRequest.toJson()['version'], 1);
    expect(f.proposed.modelRequest!.toJson()['version'], 2);
    expect(
      SelectedRepairRequest.reservedFingerprint(f.proposed),
      origin.reservationSha256,
    );
    final reference = SelectedRepairRequestReference.forProposed(
      origin,
      f.proposed,
    );
    SelectedRepairRequestReference.decode(reference.encode())
        .requireMatch(origin, f.proposed);
    expect(() => origin.sourceSha256.clear(), throwsUnsupportedError);
  });
  test('explicit origin identity prevents retargeting to another valid requested task', () async {
    final f = await selectedRepairFixture();
    final other = SelectedRepairRequest.fromJson({
      ...f.origin.toJson(),
      'boardTaskId': 'Ttest',
    });
    other.requireAttempt(
      f.proposed,
    ); // The bare old attempt does not record requested task.
    final reference = SelectedRepairRequestReference.forProposed(
      f.origin,
      f.proposed,
    );
    expect(
      () => reference.requireMatch(other, f.proposed),
      throwsFormatException,
    );
    expect(
      SelectedRepairRequestReference.forProposed(
        other,
        f.proposed,
      ).originSha256,
      isNot(reference.originSha256),
    );
  });
  test(
    'malformed shape, duplicate/version, byte and integer bounds fail closed',
    () async {
      final f = await selectedRepairFixture();
      final raw = f.origin.encode();
      for (final bad in [
        ' $raw',
        raw.replaceFirst('"version":1', '"version":1,"version":1'),
        raw.replaceFirst('"version":1', '"version":2'),
        ' ' * (SelectedRepairRequest.maxEncodedBytes + 1),
      ]) {
        expect(() => SelectedRepairRequest.decode(bad), throwsFormatException);
      }
      for (final patch in <String, Object?>{
        'extra': true,
        'attemptNumber': 9007199254740992,
        'requestSessionRecord': ' ' * (AgentSession.maxEncodedBytes + 1),
        'workingSha256': 'A' * 64,
      }.entries) {
        expect(
          () => SelectedRepairRequest.fromJson({
            ...f.origin.toJson(),
            patch.key: patch.value,
          }),
          throwsFormatException,
        );
      }
      final ref = SelectedRepairRequestReference.forProposed(
        f.origin,
        f.proposed,
      ).encode();
      for (final bad in [
        ' $ref',
        ref.replaceFirst('"version":1', '"version":1,"version":1'),
        ref.replaceFirst('"attemptNumber":1', '"attemptNumber":0'),
        ' ' * (SelectedRepairRequestReference.maxEncodedBytes + 1),
      ]) {
        expect(
          () => SelectedRepairRequestReference.decode(bad),
          throwsFormatException,
        );
      }
    },
  );
  test('task, source subset including unchanged inputs, model and entry digests must agree', () async {
    final f = await selectedRepairFixture();
    for (final patch in <String, Object?>{
      'boardTaskId': 'missing',
      'requirementId': 'other',
      'sourceSha256': {
        'lib/main.dart': f.origin.sourceSha256['lib/main.dart'],
        'lib/uncaptured.dart': 'a' * 64,
      },
      'reservationSha256': 'b' * 64,
      'failedRunSha256': 'c' * 64,
      'modelRequest': const ModelRequestProvenance(
        model: 'other',
        outputTokens: 4096,
      ).toJson(),
    }.entries) {
      expect(
        () => SelectedRepairRequest.fromJson({
          ...f.origin.toJson(),
          patch.key: patch.value,
        }).requireAttempt(f.proposed),
        throwsFormatException,
        reason: patch.key,
      );
    }
    final wrongVersion = SelectedRepairRequest.fromJson({
      ...f.origin.toJson(),
      'reservationSha256': SelectedRepairRequest.fingerprint(
        jsonEncode(
          RepairAttempt(
            number: f.proposed.number,
            startedAt: f.proposed.startedAt,
            failure: f.proposed.failure,
            status: RepairAttemptStatus.reserved,
            modelRequest: f.proposed.modelRequest!.withResponseModel(null),
          ).toJson(),
        ),
      ),
    });
    expect(
      () => wrongVersion.requireAttempt(f.proposed),
      throwsFormatException,
    );
  });
  test('reserved/local failure/cancellation cannot become a returned proposed reference', () async {
    final f = await selectedRepairFixture();
    for (final status in [
      RepairAttemptStatus.reserved,
      RepairAttemptStatus.failed,
      RepairAttemptStatus.cancelled,
    ]) {
      final attempt = RepairAttempt(
        number: f.reserved.number,
        startedAt: f.reserved.startedAt,
        failure: f.reserved.failure,
        status: status,
        modelRequest: f.reserved.modelRequest,
      );
      f.origin.requireAttempt(attempt);
      expect(
        () => SelectedRepairRequestReference.forProposed(f.origin, attempt),
        throwsFormatException,
      );
    }
  });
}
