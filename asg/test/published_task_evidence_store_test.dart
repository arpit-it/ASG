// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/controllers/source_candidate_controller.dart';
import 'package:asg/controllers/source_generation_controller.dart';
import 'package:asg/models/agent_session.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/candidate_reopen_context.dart';
import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/manual_check_observation_store.dart';
import 'package:asg/services/named_check_observation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/published_task_evidence_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_session_publication_test.dart' show publishedFixture;
import 'candidate_reopen_context_test.dart' show reopenFixture;
import 'planning_conversation_test.dart' show project;
import 'saved_candidate_recovery_controller_test.dart'
    show ReopenInspectionHost;
import 'source_candidate_controller_test.dart' show AtomicRecords;
import 'named_check_observation_test.dart' as named;

typedef EvidenceFixture = ({
  AtomicRecords records,
  AgentSession session,
  CandidateVerificationRun run,
});
Future<EvidenceFixture> evidenceFixture({
  bool withRules = true,
  bool allAuthoredRules = false,
  String taskId = 'Tanalyze',
}) async {
  if (!withRules) {
    final f = await publishedFixture();
    return (records: f.fixture.records, session: f.session, run: f.run);
  }
  final old = await reopenFixture(), records = old.records;
  final boards = RequirementsStore(records), initial = boards.load(project.id);
  final first = initial.requirements.first;
  final board = await boards.save(
    project.id,
    initial,
    RequirementsBoard(
      requirements: [
        ProjectRequirement(
          id: first.id,
          title: first.title,
          acceptance: first.acceptance,
          checks: const [
            AcceptanceCheckDefinition(
              id: 'Auto',
              type: AcceptanceCheckType.automated,
              expectation: 'Exact named fixture test',
              target: named.target,
            ),
            AcceptanceCheckDefinition(
              id: 'Manual',
              type: AcceptanceCheckType.manual,
              expectation: 'Human fixture observation',
            ),
            AcceptanceCheckDefinition(
              id: 'Advice',
              type: AcceptanceCheckType.advisory,
              expectation: 'Advisory only',
            ),
          ],
          criteria: [
            AcceptanceCriterionDefinition(
              id: 'AC1',
              text: 'Authored named-test contract',
              checkIds: ['Auto'],
              verificationRule: CriterionVerificationRule.allMappedNamedTests,
            ),
            if (!allAuthoredRules)
              AcceptanceCriterionDefinition(
                id: 'AC2',
                text: 'Manual criterion',
                checkIds: ['Manual'],
              ),
            if (!allAuthoredRules)
              AcceptanceCriterionDefinition(
                id: 'AC3',
                text: 'Unmapped criterion',
              ),
            if (!allAuthoredRules)
              AcceptanceCriterionDefinition(
                id: 'AC4',
                text: 'Advisory criterion',
                checkIds: ['Advice'],
              ),
          ],
        ),
        ProjectRequirement(
          id: 'Other',
          title: 'Unrelated requirement',
          acceptance: 'Do not leak unrelated review',
        ),
      ],
      tasks: initial.tasks,
    ),
  );
  final approvals = PlanApprovalStore(records);
  final messages = [
    ChatMessage(
      role: 'assistant',
      content: old.basis.evidence.approval.content,
      planContext: approvals.contextFor(project),
    ),
  ];
  await ConversationStore(records).save(project.id, messages);
  await approvals.save(project, messages, true);
  final approval = approvals.requireCurrentApproval(project);
  final tasks = BuildPlan.parse(approval.content, board: board).tasks;
  final working = GeneratedProject.fromJson({
    ...old.basis.working.toJson(),
    'approval': approval.toJson(),
    'tasks': tasks.map((t) => t.toJson()).toList(),
  });
  await SourceGenerationStore(records).save(project.id, working);
  final prepared = GeneratedProject.fromJson({
    ...old.basis.prepared.toJson(),
    'approval': approval.toJson(),
    'tasks': tasks.map((t) => t.toJson()).toList(),
  });
  final evidence = ApprovedSourceProposal(
    projectId: project.id,
    boardTaskId: taskId,
    approval: approval,
    proposal: old.basis.evidence.proposal,
    modelRequest: old.basis.evidence.modelRequest,
  );
  final basis = CandidateReopenBasis.capture(
    projectId: project.id,
    workingRecord: records.getString('studio.generation.v1.${project.id}')!,
    working: working,
    sourceBase: working,
    prepared: prepared,
    evidence: evidence,
  );
  final selected = await AgentSessionStore(
    records,
    project,
  ).create('evidence-review', board.tasks.map((t) => t.id).toList());
  final owner = SourceGenerationController(
    project: project,
    definition: ApplicationStore(records).load(project).definition,
    store: SourceGenerationStore(records),
    host: ReopenInspectionHost(),
    selectedSession: selected,
  );
  final candidate = SourceCandidateController(
    project: project,
    candidate: prepared,
    evidence: evidence,
    records: records,
    host: ReopenInspectionHost(),
    reopenBasis: basis,
    sessionBinding: AgentSessionBinding.select(
      session: selected,
      projectId: project.id,
      boardTaskId: taskId,
    ),
    publish: (value, host, authorize) => owner.promoteCandidate(
      value,
      host,
      authorize,
      expectedWorking: working,
    ),
  );
  await candidate.verify(approved: true);
  expect(candidate.error, isNull);
  expect(await candidate.promote(approved: true), isTrue);
  final result = (
    records: records,
    session: candidate.sessionBinding!.session,
    run: candidate.history.last,
  );
  candidate.dispose();
  owner.dispose();
  final report = RequirementCheckReportStore(records);
  await report.recordNamedTestResult(
    project,
    report.load(project),
    first.id,
    'Auto',
    named.result(true),
    DateTime.utc(2026),
    authorized: () => true,
  );
  await report.recordManualObservation(
    project,
    report.load(project),
    first.id,
    'Manual',
    true,
    DateTime.utc(2026),
    authorized: () => true,
  );
  return result;
}

class ReadOnlyEvidenceRecords implements RecordStorage {
  ReadOnlyEvidenceRecords(this.source);
  final AtomicRecords source;
  int writes = 0;
  void Function(String key)? onRead;
  @override
  String? getString(String key) {
    final value = source.getString(key);
    onRead?.call(key);
    return value;
  }

  @override
  Future<bool> setString(String key, String value) async {
    writes++;
    throw StateError('No review writes');
  }
}

void main() {
  test(
    'a different valid working record cannot retarget the selected publication',
    () async {
      final f = await evidenceFixture();
      final key = 'studio.generation.v1.${project.id}';
      final value =
          jsonDecode(f.records.getString(key)!) as Map<String, dynamic>;
      value['directory'] = '/different-working-publication';
      f.records.values[key] = jsonEncode(value);
      expect(
        RequirementCheckReportStore(f.records).load(project).savedInputsCurrent,
        isTrue,
      );
      final before = Map.of(f.records.values);
      expect(
        () => PublishedTaskEvidenceStore(
          f.records,
          project,
        ).load(f.session, f.run.number),
        throwsFormatException,
      );
      expect(f.records.values, before);
    },
  );

  test('well-formed foreign publication and stale named observation remain distinct', () async {
    final f = await evidenceFixture();
    final namedKey = NamedCheckObservationStore.key(project.id);
    final values =
        jsonDecode(f.records.getString(namedKey)!) as Map<String, dynamic>;
    ((values['observations'] as List).single as Map)['runSha256'] = 'a' * 64;
    f.records.values[namedKey] = jsonEncode(values);
    final value = PublishedTaskEvidenceStore(
      f.records,
      project,
    ).load(f.session, f.run.number);
    expect(value.checks.first.label, contains('stale'));
    expect(value.criteria.first.verdict, 'Criterion acceptance: not verified');
    final key =
        'studio.agentSessionPublication.v1.${project.id}.${f.run.number}';
    final publication =
        jsonDecode(f.records.getString(key)!) as Map<String, dynamic>;
    (publication['session'] as Map)['sessionId'] = 'foreign';
    f.records.values[key] = jsonEncode(publication);
    final before = Map.of(f.records.values);
    expect(
      () => PublishedTaskEvidenceStore(
        f.records,
        project,
      ).load(f.session, f.run.number),
      throwsFormatException,
    );
    expect(f.records.values, before);
  });

  test('exact publication scopes current criteria/check facts without writes or execution services', () async {
    final f = await evidenceFixture(),
        records = ReadOnlyEvidenceRecords(f.records);
    final before = Map.of(f.records.values);
    final value = PublishedTaskEvidenceStore(
      records,
      project,
    ).load(f.session, f.run.number);
    expect(value.taskId, 'Tanalyze');
    expect(value.requirementId, 'R1');
    expect(value.criteria, hasLength(4));
    expect(value.checks, hasLength(3));
    expect(
      value.criteria.first.verdict,
      contains('verified against authored named tests'),
    );
    expect(value.criteria[1].verdict, 'Criterion acceptance: not verified');
    expect(value.criteria[2].summary, contains('no mappings'));
    expect(value.criteria[3].verdict, 'Criterion acceptance: not verified');
    expect(value.checks[1].label, contains('self-reported'));
    expect(value.checks[2].label, contains('no acceptance verdict'));
    expect(records.writes, 0);
    expect(f.records.values, before);
    expect(() => value.checks.clear(), throwsUnsupportedError);
    expect(() => value.criteria.first.checkIds.clear(), throwsUnsupportedError);
    expect(() => value.checks.first.facts.clear(), throwsUnsupportedError);
  });

  test('missing criteria do not produce an aggregate or vacuous pass, and withdrawal stays read-only', () async {
    final f = await evidenceFixture(withRules: false);
    final session = await AgentSessionStore(
      f.records,
      project,
    ).requestCancellation(f.session);
    final before = Map.of(f.records.values);
    final value = PublishedTaskEvidenceStore(
      f.records,
      project,
    ).load(session, f.run.number);
    expect(value.criteria, isEmpty);
    expect(value.checks, isEmpty);
    expect(value.withdrawn, isTrue);
    expect(f.records.values, before);
  });

  test('independently changed publication/run/checkpoint/session/working/approval/board/input/check records fail closed', () async {
    final f = await evidenceFixture();
    final baseline = Map.of(f.records.values);
    final keys = [
      'studio.agentSessionPublication.v1.${project.id}.${f.run.number}',
      'studio.candidateChecks.v1.${project.id}',
      'studio.agentExecution.v1.${f.run.dispatchId!.split(':').first}',
      f.session.storageKey,
      'studio.generation.v1.${project.id}',
      'studio.planApproval.v1.${project.id}',
      RequirementsStore.key(project.id),
      'studio.application.v1.${project.id}',
      NamedCheckObservationStore.key(project.id),
      ManualCheckObservationStore.key(project.id),
    ];
    for (final key in keys) {
      f.records.values
        ..clear()
        ..addAll(baseline);
      f.records.values[key] = key.startsWith('studio.generation.')
          ? '${baseline[key]} '
          : '{private token /private/source';
      final before = Map.of(f.records.values);
      expect(
        () => PublishedTaskEvidenceStore(
          f.records,
          project,
        ).load(f.session, f.run.number),
        throwsFormatException,
        reason: key,
      );
      expect(f.records.values, before);
    }
  });

  test('replaced named result updates a fresh projection without mutating the previous snapshot', () async {
    final f = await evidenceFixture();
    final store = PublishedTaskEvidenceStore(f.records, project);
    final original = store.load(f.session, f.run.number);
    final report = RequirementCheckReportStore(f.records);
    await report.recordNamedTestResult(
      project,
      report.load(project),
      'R1',
      'Auto',
      named.result(false),
      DateTime.utc(2026, 2),
      authorized: () => true,
    );
    final value = store.load(f.session, f.run.number);
    expect(value.criteria.first.verdict, 'Criterion acceptance: not verified');
    expect(value.checks.first.label, contains('did not pass'));
    expect(
      original.criteria.first.verdict,
      contains('verified against authored named tests'),
    );
  });

  test('reentrant record change while report is assembled cannot expose a mixed snapshot', () async {
    final f = await evidenceFixture(),
        records = ReadOnlyEvidenceRecords(f.records);
    var reads = 0;
    records.onRead = (key) {
      if (key == ManualCheckObservationStore.key(project.id) && ++reads == 2) {
        final working = 'studio.generation.v1.${project.id}';
        f.records.values[working] = '${f.records.values[working]} ';
      }
    };
    expect(
      () => PublishedTaskEvidenceStore(
        records,
        project,
      ).load(f.session, f.run.number),
      throwsFormatException,
    );
    expect(records.writes, 0);
  });
}
