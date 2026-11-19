// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:asg/models/candidate_verification_run.dart';
import 'package:asg/models/repair_attempt.dart';
import 'package:asg/models/selected_repair_request.dart';
import 'package:asg/services/repair_attempt_store.dart';
import 'package:asg/services/repair_request_context.dart';
import 'package:asg/services/selected_repair_request_store.dart';

import 'package:asg/controllers/source_review_controller.dart';
import 'package:asg/models/local_model_config.dart';
import 'package:asg/models/session_proposal_request.dart';
import 'package:asg/models/session_proposal_reference.dart';
import 'package:asg/services/approved_source_proposer.dart';
import 'package:asg/services/source_edit_proposer.dart';
import 'package:asg/services/model_provider.dart';
import 'package:asg/services/session_proposal_request_store.dart';
import 'package:asg/views/source_review_screen.dart';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:asg/controllers/agent_session_controller.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/named_flutter_test_result.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/models/agent_task_decision.dart';
import 'package:asg/services/agent_task_decision_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/requirement_check_report_store.dart';
import 'package:asg/models/agent_session_publication.dart';
import 'package:asg/models/agent_execution_checkpoint.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/build_task.dart';
import 'package:asg/models/candidate_reopen_context.dart';
import 'package:asg/models/model_request_provenance.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/source_edit_proposal.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_admission.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/application_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/generation_host.dart';
import 'package:asg/services/generation_input.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/source_generation_store.dart';
import 'package:asg/views/agent_session_screen.dart';

import 'agent_session_task_history.dart'
    show TaskHistoryFixture, TaskHistoryFixtureRecords;

/// Supplied in-memory inspection only. This host cannot run SDK/model/preview.
class ReopenFixtureHost
    implements GenerationHost, CandidateSourceInspectionHost {
  int inspections = 0, effectAttempts = 0, disposals = 0;
  @override
  bool get supported => true;
  @override
  Future<void> checkSources(GeneratedProject project) async {
    inspections++;
  }

  Never _effect() {
    effectAttempts++;
    throw UnsupportedError('No effects are supplied by this UI fixture.');
  }

  @override
  Future<GeneratedProject> generate({
    required StudioProject project,
    required AppDefinition definition,
    required String parent,
    required String name,
    required String sdk,
    required String python,
    void Function()? authorizeWrite,
  }) async => _effect();
  @override
  Future<GeneratedProject> verify(
    GeneratedProject project,
    GenerationProgress progress, {
    bool resume = false,
  }) async => _effect();
  @override
  void cancelVerification() {}
  @override
  Future<Uri> startPreview(GeneratedProject project) async => _effect();
  @override
  Future<void> openPreview(Uri uri) async => _effect();
  @override
  Future<void> stopPreview() async {}
  @override
  Future<void> dispose() async {
    disposals++;
  }
}

/// The optional decision fixture permits only the production single-record CAS.
class DecisionFixtureRecords implements ConditionalRecordStorage {
  DecisionFixtureRecords(this.source);
  final TaskHistoryFixtureRecords source;
  int decisionCommits = 0, unexpectedWrites = 0;
  @override
  String? getString(String key) => source.getString(key);
  @override
  Future<bool> setString(String key, String value) async {
    unexpectedWrites++;
    throw StateError('Only an explicit decision transaction is supplied.');
  }

  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    if (updates.length != 1 ||
        !updates.keys.single.startsWith(AgentTaskDecision.prefix) ||
        !expected.containsKey(updates.keys.single) ||
        expected[updates.keys.single] != null ||
        source.values.containsKey(updates.keys.single)) {
      unexpectedWrites++;
      throw StateError('Unexpected fixture write.');
    }
    if (expected.entries.any((e) => source.getString(e.key) != e.value)) {
      throw StateError('Fixture evidence changed.');
    }
    for (final e in updates.entries) {
      StudioDatabase.validate(e.key, e.value);
    }
    authorize();
    source.values.addAll(updates);
    decisionCommits++;
  }
}

class CandidateReopenFixture {
  CandidateReopenFixture._(
    this.records,
    this.baseline,
    this.decisionMode, {
    this.preparationMode = false,
  }) : decisionRecords = DecisionFixtureRecords(records),
       originalBaseline = jsonEncode({
         for (final e in records.values.entries)
           if (!e.key.startsWith(AgentTaskDecision.prefix)) e.key: e.value,
       });
  final bool preparationMode;
  final String originalBaseline;
  final bool decisionMode;
  final DecisionFixtureRecords decisionRecords;
  int fixtureMutations = 0;
  ConditionalRecordStorage get uiRecords =>
      decisionMode ? decisionRecords : records;
  bool get originalRecordsUnchanged =>
      jsonEncode({
        for (final e in records.values.entries)
          if (!e.key.startsWith(AgentTaskDecision.prefix)) e.key: e.value,
      }) ==
      originalBaseline;
  int get retainedDecisions => records.values.keys
      .where((key) => key.startsWith(AgentTaskDecision.prefix))
      .length;
  Future<void> replaceNamedObservation() async {
    records.readOnly = false;
    try {
      final report = RequirementCheckReportStore(records);
      final current = report.load(TaskHistoryFixture.project);
      final target = current.results.first.requirement.checks.first.target!;
      await report.recordNamedTestResult(
        TaskHistoryFixture.project,
        current,
        'R1',
        'Auto',
        NamedFlutterTestResult.fromCommand({
          'exitCode': 1,
          'timedOut': false,
          'cancelled': false,
          'outputLimitExceeded': false,
          'targetedTest': {
            'file': target.file,
            'name': target.name,
            'status': 'notPassed',
            'reason': 'commandFailed',
          },
        }, target),
        DateTime.utc(2026, 2),
        authorized: () => true,
      );
      fixtureMutations++;
    } finally {
      records.readOnly = true;
    }
  }

  Future<void> withdrawPublishedSession() async {
    records.readOnly = false;
    try {
      final sessions = AgentSessionStore(records, TaskHistoryFixture.project);
      await sessions.requestCancellation(sessions.load('published')!);
      fixtureMutations++;
    } finally {
      records.readOnly = true;
    }
  }

  void mutatePreparation({required bool remove}) {
    if (!preparationMode) throw StateError('Preparation fixture required.');
    final session = AgentSessionStore(
      records,
      TaskHistoryFixture.project,
    ).load('published')!;
    final key =
        '${CandidateReopenContext.prefix}${TaskHistoryFixture.project.id}.${session.dispatches.last.runNumber}';
    final saved = (jsonDecode(baseline) as Map)[key] as String;
    if (remove) {
      records.values.remove(key);
    } else {
      final value = jsonDecode(saved);
      const alternate =
          'void main() { /* supplied different reviewed base */ }';
      value['basis']['sourceBase']['sources']['lib/main.dart'] = sha256
          .convert(utf8.encode(alternate))
          .toString();
      value['basis']['evidence']['proposal']['changes'][0]['before'] =
          alternate;
      CandidateReopenContext.decode(jsonEncode(value));
      records.values[key] = jsonEncode(value);
    }
    fixtureMutations++;
  }

  final TaskHistoryFixtureRecords records;
  final String baseline;
  final hosts = <ReopenFixtureHost>[];
  bool get unchanged => jsonEncode(records.values) == baseline;
  ReopenFixtureHost createHost() {
    final host = ReopenFixtureHost();
    hosts.add(host);
    return host;
  }

  int get inspections => hosts.fold(0, (sum, host) => sum + host.inspections);
  int get effectAttempts =>
      hosts.fold(0, (sum, host) => sum + host.effectAttempts);

  static Future<CandidateReopenFixture> create({
    bool decisionMode = false,
    bool preparationMode = false,
    bool lineageMode = false,
  }) async {
    decisionMode = decisionMode || preparationMode;
    final old = await TaskHistoryFixture.create();
    final records = old.records..readOnly = false;
    const project = TaskHistoryFixture.project;
    final requirements = RequirementsStore(records);
    final initialBoard = requirements.load(project.id);
    final originalApproval = PlanApprovalStore(records).load(project.id)!;
    const target = FlutterTestTarget(
      file: 'test/app_test.dart',
      name: 'opens app',
    );
    final first = initialBoard.requirements.first;
    final board = await requirements.save(
      project.id,
      initialBoard,
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
                expectation: 'Supplied exact named-test observation',
                target: target,
              ),
              AcceptanceCheckDefinition(
                id: 'Manual',
                type: AcceptanceCheckType.manual,
                expectation: 'Supplied human observation',
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
                text: 'Supplied authored named-test rule',
                checkIds: ['Auto'],
                verificationRule: CriterionVerificationRule.allMappedNamedTests,
              ),
              if (!decisionMode)
                AcceptanceCriterionDefinition(
                  id: 'AC2',
                  text: 'Manual fixture criterion',
                  checkIds: ['Manual'],
                ),
              if (!decisionMode)
                AcceptanceCriterionDefinition(
                  id: 'AC3',
                  text: 'Unmapped fixture criterion',
                ),
              if (!decisionMode)
                AcceptanceCriterionDefinition(
                  id: 'AC4',
                  text: 'Advisory fixture criterion',
                  checkIds: ['Advice'],
                ),
            ],
          ),
          ProjectRequirement(
            id: 'Other',
            title: 'Unrelated fixture requirement',
            acceptance: 'Excluded from the selected task review',
          ),
        ],
        tasks: initialBoard.tasks,
      ),
    );
    final approvals = PlanApprovalStore(records);
    final messages = [
      ChatMessage(
        role: 'assistant',
        content: originalApproval.content,
        planContext: approvals.contextFor(project),
      ),
    ];
    await ConversationStore(records).save(project.id, messages);
    await approvals.save(project, messages, true);
    final approval = approvals.requireCurrentApproval(project);
    final tasks = BuildPlan.parse(approval.content, board: board).tasks;
    const before = 'void main() { /* saved original */ }';
    const after = 'void main() { /* reviewed fixture change */ }';
    String hash(String text) => sha256.convert(utf8.encode(text)).toString();
    final working = GeneratedProject(
      directory: '/fixture/working',
      sdk: '/fixture/sdk',
      python: 'fixture-python',
      confined: true,
      approval: approval,
      tasks: tasks,
      sources: {
        ...GenerationInput(
          project,
          ApplicationStore(records).load(project).definition,
        ).fingerprints,
        'lib/main.dart': hash(before),
      },
      steps: [
        for (final task in tasks)
          GenerationStep(
            operation: task.operation.name,
            exitCode: 0,
            output: 'supplied fixture value',
          ),
      ],
      outputs: {'index.html': 'a' * 64, 'main.dart.js': 'b' * 64},
      phase: SourceGenerationPhase.ready,
    );
    await SourceGenerationStore(records).save(project.id, working);
    final proposal = SourceEditProposal.parse(
      {
        'summary': 'Recorded fixture change',
        'changes': [
          {'path': 'lib/main.dart', 'before': before, 'after': after},
        ],
      },
      originals: {'lib/main.dart': before},
      responseModel: lineageMode
          ? 'supplied-lineage-model'
          : 'fixture-response',
    );
    final request = ModelRequestProvenance(
      model: lineageMode ? 'supplied-lineage-model' : 'fixture-request',
      outputTokens: 4096,
      responseModel: lineageMode
          ? 'supplied-lineage-model'
          : 'fixture-response',
    );
    final evidence = ApprovedSourceProposal(
      projectId: project.id,
      boardTaskId: 'Tresolve',
      approval: approval,
      proposal: proposal,
      modelRequest: request,
    );
    final prepared = GeneratedProject(
      directory: '/fixture/candidate',
      sdk: working.sdk,
      python: working.python,
      confined: true,
      approval: approval,
      tasks: tasks,
      sourceRequest: request,
      sources: {...working.sources, 'lib/main.dart': hash(after)},
    );
    final basis = CandidateReopenBasis.capture(
      projectId: project.id,
      workingRecord: records.getString('studio.generation.v1.${project.id}')!,
      working: working,
      sourceBase: working,
      prepared: prepared,
      evidence: evidence,
    );
    final sessions = AgentSessionStore(records, project);
    final selected = await sessions.create(
      'recoverable',
      board.tasks.map((task) => task.id).toList(),
    );
    SessionProposalOrigin? initialOrigin;
    if (lineageMode) {
      // Explicit supplied setup only; no transport, model, SDK or host execution.
      final history = SessionProposalRequestStore(
        records,
        project.id,
        selected.sessionId,
      );
      await history.reserve(
        project: project,
        binding: AgentSessionBinding.select(
          session: selected,
          projectId: project.id,
          boardTaskId: 'Tresolve',
        ),
        workingRecord: records.getString('studio.generation.v1.${project.id}')!,
        originals: {'lib/main.dart': before},
        modelRequest: const ModelRequestProvenance(
          model: 'supplied-lineage-model',
          outputTokens: 4096,
        ),
        authorize: () {},
      );
      await history.finish(
        SessionProposalRequestStatus.returnedValidated,
        proposal: proposal,
        authorizeReturn: () {},
      );
      initialOrigin = history.returnedOrigin;
    }
    final journal = CandidateVerificationStore(records, project.id);
    final run = await journal.start(
      prepared.copy(phase: SourceGenerationPhase.verifying),
      () {},
      reopenBasis: basis,
      initialRequestOrigin: initialOrigin,
      sessionAdmission: AgentSessionRunAdmission(
        records,
        project,
        AgentSessionBinding.select(
          session: selected,
          projectId: project.id,
          boardTaskId: 'Tresolve',
        ),
      ),
    );
    await journal.checkpoint(
      run.snapshot.copy(pendingOperation: 'resolve'),
      () {},
    );
    // These are supplied deterministic observations, not SDK/promotion execution.
    await journal.acknowledgeStopped(journal.load().runs.last, () {});
    final publicationSelection = await sessions.create(
      'published',
      board.tasks.map((task) => task.id).toList(),
    );
    final publicationJournal = CandidateVerificationStore(records, project.id);
    final publicationRun = await publicationJournal.start(
      prepared.copy(phase: SourceGenerationPhase.verifying),
      () {},
      reopenBasis: basis,
      sessionAdmission: AgentSessionRunAdmission(
        records,
        project,
        AgentSessionBinding.select(
          session: publicationSelection,
          projectId: project.id,
          boardTaskId: 'Tresolve',
        ),
      ),
    );
    var supplied = publicationRun.snapshot;
    for (final task in tasks) {
      await publicationJournal.checkpoint(
        supplied.copy(pendingOperation: task.operation.name),
        () {},
      );
      supplied = supplied.copy(
        pendingOperation: '',
        steps: [
          ...supplied.steps,
          GenerationStep(
            operation: task.operation.name,
            exitCode: 0,
            output: 'supplied fixture value; no SDK was run',
          ),
        ],
      );
      await publicationJournal.checkpoint(supplied, () {});
    }
    supplied = supplied.copy(
      phase: SourceGenerationPhase.ready,
      outputs: working.outputs,
    );
    await publicationJournal.checkpoint(supplied, () {}, finished: true);
    final finished = publicationJournal.load().runs.last;
    final admitted = publicationJournal.admittedSession!;
    final workingKey = 'studio.generation.v1.${project.id}';
    final executionKey =
        'studio.agentExecution.v1.candidate-${project.id}-${finished.number}';
    final originalWorking = records.getString(workingKey)!;
    final publishedWorking = SourceGenerationStore(records)
        .encodeUpdate(project.id, supplied);
    final publication = AgentSessionPublication.capture(
      session: admitted,
      run: finished,
      originalWorkingRecord: originalWorking,
      publishedWorkingRecord: publishedWorking,
      executionBefore: AgentExecutionCheckpoint.fromJson(
        jsonDecode(records.getString(executionKey)!),
      ),
    );
    await records.commitRecords(
      expected: {
        workingKey: originalWorking,
        publication.storageKey: null,
        executionKey: records.getString(executionKey),
        admitted.storageKey: records.getString(admitted.storageKey),
      },
      updates: {
        workingKey: publishedWorking,
        'studio.generationPrevious.v1.${project.id}': originalWorking,
        executionKey: jsonEncode(publication.executionAfter.toJson()),
        publication.storageKey: jsonEncode(publication.toJson()),
      },
      authorize: () {},
    );
    final report = RequirementCheckReportStore(records);
    final suppliedNamedResult = NamedFlutterTestResult.fromCommand({
      'exitCode': 0,
      'timedOut': false,
      'cancelled': false,
      'outputLimitExceeded': false,
      'targetedTest': {
        'file': target.file,
        'name': target.name,
        'status': 'passed',
        'reason': 'executedExactTest',
      },
    }, target);
    await report.recordNamedTestResult(
      project,
      report.load(project),
      first.id,
      'Auto',
      suppliedNamedResult,
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
    if (preparationMode) {
      // Supplied setup facts only: no verification host or SDK/model is called.
      final decisions = AgentTaskDecisionStore(records, project);
      final rootSession = sessions.load('published')!;
      final rootNumber = rootSession.dispatches.last.runNumber;
      await decisions.confirm(
        decisions.select(rootSession, rootNumber),
        consent: true,
        authorized: () => true,
      );
      const dependentAfter = '$after\n// supplied dependent preparation';
      final dependentEvidence = ApprovedSourceProposal(
        projectId: project.id,
        boardTaskId: 'Tanalyze',
        approval: approval,
        modelRequest: request,
        proposal: SourceEditProposal.parse(
          {
            'summary': 'Supplied dependent review',
            'changes': [
              {
                'path': 'lib/main.dart',
                'before': after,
                'after': dependentAfter,
              },
            ],
          },
          originals: {'lib/main.dart': after},
          responseModel: request.responseModel,
        ),
      );
      final dependentPrepared = GeneratedProject.fromJson({
        ...supplied.toJson(),
        'directory': '/fixture/dependent-candidate',
        'phase': SourceGenerationPhase.generated.name,
        'steps': <Object>[],
        'outputs': <String, String>{},
        'sources': {...supplied.sources, 'lib/main.dart': hash(dependentAfter)},
      });
      final dependentBasis = CandidateReopenBasis.capture(
        projectId: project.id,
        workingRecord: records.getString(workingKey)!,
        working: supplied,
        sourceBase: supplied,
        prepared: dependentPrepared,
        evidence: dependentEvidence,
      );
      final prerequisiteSession = sessions.load('published')!;
      final dependentPublicationJournal = CandidateVerificationStore(
        records,
        project.id,
      );
      final dependentPublicationRun = await dependentPublicationJournal.start(
        dependentPrepared.copy(phase: SourceGenerationPhase.verifying),
        () {},
        reopenBasis: dependentBasis,
        sessionAdmission: AgentSessionRunAdmission(
          records,
          project,
          AgentSessionBinding.select(
            session: prerequisiteSession,
            projectId: project.id,
            boardTaskId: 'Tanalyze',
          ),
        ),
      );
      var dependentSupplied = dependentPublicationRun.snapshot;
      for (final task in tasks) {
        await dependentPublicationJournal.checkpoint(
          dependentSupplied.copy(pendingOperation: task.operation.name),
          () {},
        );
        dependentSupplied = dependentSupplied.copy(
          pendingOperation: '',
          steps: [
            ...dependentSupplied.steps,
            GenerationStep(
              operation: task.operation.name,
              exitCode: 0,
              output: 'dependentSupplied fixture value; no SDK was run',
            ),
          ],
        );
        await dependentPublicationJournal.checkpoint(dependentSupplied, () {});
      }
      dependentSupplied = dependentSupplied.copy(
        phase: SourceGenerationPhase.ready,
        outputs: working.outputs,
      );
      await dependentPublicationJournal.checkpoint(
        dependentSupplied,
        () {},
        finished: true,
      );
      final dependentFinished = dependentPublicationJournal.load().runs.last;
      final dependentAdmitted = dependentPublicationJournal.admittedSession!;
      final dependentWorkingKey = 'studio.generation.v1.${project.id}';
      final dependentExecutionKey =
          'studio.agentExecution.v1.candidate-${project.id}-${dependentFinished.number}';
      final dependentOriginalWorking = records.getString(dependentWorkingKey)!;
      final dependentPublishedWorking = SourceGenerationStore(records)
          .encodeUpdate(project.id, dependentSupplied);
      final dependentPublication = AgentSessionPublication.capture(
        session: dependentAdmitted,
        run: dependentFinished,
        originalWorkingRecord: dependentOriginalWorking,
        publishedWorkingRecord: dependentPublishedWorking,
        executionBefore: AgentExecutionCheckpoint.fromJson(
          jsonDecode(records.getString(dependentExecutionKey)!),
        ),
      );
      await records.commitRecords(
        expected: {
          dependentWorkingKey: dependentOriginalWorking,
          dependentPublication.storageKey: null,
          dependentExecutionKey: records.getString(dependentExecutionKey),
          dependentAdmitted.storageKey: records.getString(
            dependentAdmitted.storageKey,
          ),
        },
        updates: {
          dependentWorkingKey: dependentPublishedWorking,
          'studio.generationPrevious.v1.${project.id}':
              dependentOriginalWorking,
          dependentExecutionKey: jsonEncode(
            dependentPublication.executionAfter.toJson(),
          ),
          dependentPublication.storageKey: jsonEncode(
            dependentPublication.toJson(),
          ),
        },
        authorize: () {},
      );

      await report.recordNamedTestResult(
        project,
        report.load(project),
        first.id,
        'Auto',
        suppliedNamedResult,
        DateTime.utc(2026, 3),
        authorized: () => true,
      );
      await decisions.confirm(
        decisions.select(
          dependentAdmitted,
          dependentFinished.number,
          prerequisites: {'Tresolve': rootNumber},
        ),
        consent: true,
        authorized: () => true,
      );
    }
    if (!decisionMode) await sessions.requestCancellation(admitted);
    records.readOnly = true;
    records.writeAttempts = 0;
    return CandidateReopenFixture._(
      records,
      jsonEncode(records.values),
      decisionMode,
      preparationMode: preparationMode,
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (const bool.fromEnvironment('ASG_REPAIR_LINEAGE_FIXTURE')) {
    runApp(
      MaterialApp(home: await selectedRepairFixtureHome(lineageMode: true)),
    );
    return;
  }
  if (const bool.fromEnvironment('ASG_SELECTED_REPAIR_FIXTURE')) {
    runApp(MaterialApp(home: await selectedRepairFixtureHome()));
    return;
  }
  if (const bool.fromEnvironment('ASG_REQUEST_HISTORY_FIXTURE')) {
    runApp(
      MaterialApp(
        home: _RequestFixtureHome(await RequestHistoryFixture.create()),
      ),
    );
    return;
  }
  final fixture = await CandidateReopenFixture.create(
    decisionMode: const bool.fromEnvironment('ASG_TASK_DECISION_FIXTURE'),
    preparationMode: const bool.fromEnvironment('ASG_PREPARATION_FIXTURE'),
    lineageMode: const bool.fromEnvironment('ASG_LINEAGE_FIXTURE'),
  );
  runApp(MaterialApp(home: _FixtureHome(fixture)));
}

class _FixtureHome extends StatefulWidget {
  const _FixtureHome(this.fixture);
  final CandidateReopenFixture fixture;
  @override
  State<_FixtureHome> createState() => _FixtureHomeState();
}

class _FixtureHomeState extends State<_FixtureHome> {
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(
        const bool.fromEnvironment('ASG_LINEAGE_FIXTURE')
            ? 'Initial request lineage UI fixture'
            : widget.fixture.preparationMode
            ? 'Prerequisite preparation UI fixture'
            : widget.fixture.decisionMode
            ? 'Authored-check decision UI fixture'
            : 'Published-task evidence UI fixture',
      ),
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (const bool.fromEnvironment('ASG_LINEAGE_FIXTURE'))
          const Text(
            'Supplied initial request lineage fixture. The recoverable run retains request 1 with supplied-lineage-model; no live inference or command execution. Other historical fixture identities remain unchanged.',
          ),
        const Text(
          'Deterministic in-memory publication, named-test and manual observations. No SDK, files, model or preview runs. Default records refuse writes after setup; the labelled decision fixture permits only explicit decision records.',
        ),
        Text(
          'Write attempts after setup: ${widget.fixture.records.writeAttempts}',
        ),
        Text('Records unchanged: ${widget.fixture.unchanged}'),
        if (widget.fixture.preparationMode) ...[
          const Text(
            'Two historical decisions and their publication/check facts were supplied during setup. Opening the production review performs no writes or execution.',
          ),
          OutlinedButton(
            onPressed: () {
              widget.fixture.mutatePreparation(remove: false);
              setState(() {});
            },
            child: const Text('Supply a different reviewed preparation base'),
          ),
          OutlinedButton(
            onPressed: () {
              widget.fixture.mutatePreparation(remove: true);
              setState(() {});
            },
            child: const Text('Remove supplied preparation context'),
          ),
        ],
        if (widget.fixture.decisionMode) ...[
          const Text(
            'Decision fixture: only explicit one-record decision transactions are permitted. Named-test observations are supplied, not new SDK execution.',
          ),
          Text(
            'Original records unchanged: ${widget.fixture.originalRecordsUnchanged}',
          ),
          Text(
            'Decision commits: ${widget.fixture.decisionRecords.decisionCommits}',
          ),
          Text('Retained decisions: ${widget.fixture.retainedDecisions}'),
          Text(
            'Unexpected writes: ${widget.fixture.decisionRecords.unexpectedWrites}',
          ),
          Text(
            'Explicit fixture evidence mutations: ${widget.fixture.fixtureMutations}',
          ),
          OutlinedButton(
            onPressed: () async {
              await widget.fixture.replaceNamedObservation();
              if (mounted) setState(() {});
            },
            child: const Text(
              'Replace supplied named observation with failure',
            ),
          ),
          OutlinedButton(
            onPressed: () async {
              await widget.fixture.withdrawPublishedSession();
              if (mounted) setState(() {});
            },
            child: const Text('Withdraw supplied published session'),
          ),
        ],
        Text('Supplied source inspections: ${widget.fixture.inspections}'),
        Text(
          'Command/model/preview attempts: ${widget.fixture.effectAttempts}',
        ),
        FilledButton(
          onPressed: () async {
            final controller = AgentSessionController(
              AgentSessionStore(
                widget.fixture.uiRecords,
                TaskHistoryFixture.project,
              ),
              createRecoveryHost: widget.fixture.createHost,
            );
            controller.load();
            controller.open('published');
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AgentSessionScreen(
                  controller: controller,
                  projectName: 'Publication fixture — production screens',
                ),
              ),
            );
            if (mounted) setState(() {});
          },
          child: const Text('Open saved publication history fixture'),
        ),
      ],
    ),
  );
}

/// An explicit supplied-request fixture, separate from all live model evidence.
class RequestHistoryFixtureRecords implements ConditionalRecordStorage {
  RequestHistoryFixtureRecords(this.source, this.journalKey);
  final TaskHistoryFixtureRecords source;
  final String journalKey;
  int commits = 0, unexpectedWrites = 0;
  bool failRead = false, failOutcome = false;
  @override
  String? getString(String key) {
    if (failRead && key == journalKey) {
      throw StateError('Supplied private history read error');
    }
    return source.getString(key);
  }

  @override
  Future<bool> setString(String key, String value) async {
    unexpectedWrites++;
    throw StateError(
      'Only explicit request journal transactions are supplied.',
    );
  }

  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    if (updates.length != 1 ||
        !updates.containsKey(journalKey) ||
        !expected.containsKey(journalKey)) {
      unexpectedWrites++;
      throw StateError('Unexpected supplied fixture transaction.');
    }
    final next = SessionProposalRequestStore.decode(
      journalKey,
      updates[journalKey]!,
    );
    if (failOutcome &&
        next.requests.last.status != SessionProposalRequestStatus.reserved) {
      throw StateError('Supplied outcome persistence failure');
    }
    source.readOnly = false;
    try {
      await source.commitRecords(
        expected: expected,
        updates: updates,
        authorize: authorize,
      );
      commits++;
    } finally {
      source.readOnly = true;
    }
  }
}

class _SuppliedRequestProvider
    implements ModelProvider, ModelResponseIdentityProvider {
  _SuppliedRequestProvider(this.model, {required this.failCleanup});
  final String model;
  final bool failCleanup;
  @override
  String get completedResponseModel => model;
  @override
  Stream<String> generate(String prompt) => Stream.value(
    jsonEncode({
      'summary': 'Supplied fixture replacement for review only',
      'changes': [
        {
          'path': 'lib/main.dart',
          'before': RequestHistoryFixture.before,
          'after': RequestHistoryFixture.after,
        },
      ],
    }),
  );
  @override
  Future<void> cancel() async {
    if (failCleanup) throw StateError('Supplied transport cleanup failure');
  }
}

class RequestHistoryFixture {
  RequestHistoryFixture._(this.records, this.originalBaseline);
  final RequestHistoryFixtureRecords records;
  final String originalBaseline;
  static const before = 'void main() { /* supplied request original */ }';
  static const after = 'void main() { /* supplied request replacement */ }';
  static const sessionId = 'request-history';
  final host = ReopenFixtureHost();
  int providerCreations = 0, sourceCaptures = 0, fixtureControls = 0;
  bool failCleanup = false;
  bool get originalsUnchanged =>
      jsonEncode({
        for (final e in records.source.values.entries)
          if (e.key != records.journalKey) e.key: e.value,
      }) ==
      originalBaseline;
  static Future<RequestHistoryFixture> create() async {
    final base = await TaskHistoryFixture.create();
    final raw = base.records..readOnly = false;
    const project = TaskHistoryFixture.project;
    final approval = PlanApprovalStore(raw).requireCurrentApproval(project);
    final board = RequirementsStore(raw).load(project.id);
    await SourceGenerationStore(raw).save(
      project.id,
      GeneratedProject(
        directory: '/fixture/request-working',
        sdk: '/fixture/sdk',
        python: 'fixture-python',
        confined: true,
        approval: approval,
        tasks: BuildPlan.parse(approval.content, board: board).tasks,
        sources: {
          ...GenerationInput(
            project,
            ApplicationStore(raw).load(project).definition,
          ).fingerprints,
          'lib/main.dart': SessionProposalRequestStore.fingerprint(before),
        },
      ),
    );
    final selected = await AgentSessionStore(
      raw,
      project,
    ).create(sessionId, board.tasks.map((t) => t.id).toList());
    final binding = AgentSessionBinding.select(
      session: selected,
      projectId: project.id,
      boardTaskId: 'Tresolve',
    );
    final working = raw.getString('studio.generation.v1.${project.id}')!;
    for (final status in SessionProposalRequestStatus.values) {
      final store = SessionProposalRequestStore(raw, project.id, sessionId);
      await store.reserve(
        project: project,
        binding: binding,
        workingRecord: working,
        originals: const {'lib/main.dart': before},
        modelRequest: const ModelRequestProvenance(
          model: 'supplied-request-model',
          outputTokens: 4096,
        ),
        authorize: () {},
      );
      if (status != SessionProposalRequestStatus.reserved) {
        await store.finish(
          status,
          proposal: status == SessionProposalRequestStatus.returnedValidated
              ? SourceEditProposal.parse(
                  {
                    'summary': 'Supplied setup return, not live model output',
                    'changes': [
                      {
                        'path': 'lib/main.dart',
                        'before': before,
                        'after': after,
                      },
                    ],
                  },
                  originals: const {'lib/main.dart': before},
                  responseModel: 'supplied-request-model',
                )
              : null,
          authorizeReturn:
              status == SessionProposalRequestStatus.returnedValidated
              ? () {}
              : null,
        );
      }
    }
    final key = SessionProposalRequestStore(raw, project.id, sessionId).key;
    final baseline = jsonEncode({
      for (final e in raw.values.entries)
        if (e.key != key) e.key: e.value,
    });
    raw.readOnly = true;
    raw.writeAttempts = 0;
    return RequestHistoryFixture._(
      RequestHistoryFixtureRecords(raw, key),
      baseline,
    );
  }

  Future<void> withdraw() async {
    records.source.readOnly = false;
    try {
      final store = AgentSessionStore(
        records.source,
        TaskHistoryFixture.project,
      );
      await store.requestCancellation(store.load(sessionId)!);
      fixtureControls++;
    } finally {
      records.source.readOnly = true;
    }
  }

  SourceReviewController controller() => SourceReviewController(
    project: TaskHistoryFixture.project,
    generated: SourceGenerationStore(records)
        .load(TaskHistoryFixture.project.id)!,
    records: records,
    selectedSession: AgentSessionStore(
      records,
      TaskHistoryFixture.project,
    ).load(sessionId),
    proposer: ApprovedSourceProposer(
      records,
      proposer: SourceEditProposer(
        createProvider: (LocalModelConfig config) {
          final history = SessionProposalRequestStore(
            records,
            TaskHistoryFixture.project.id,
            sessionId,
          ).load();
          if (history.requests.last.status !=
              SessionProposalRequestStatus.reserved) {
            throw StateError('Intent must precede supplied provider creation');
          }
          providerCreations++;
          return _SuppliedRequestProvider(
            config.model,
            failCleanup: failCleanup,
          );
        },
      ),
    ),
    readSnapshot: (_, paths) async {
      sourceCaptures++;
      if (paths.length != 1 || paths.single != 'lib/main.dart') {
        throw StateError('Only supplied source capture exists');
      }
      return const {'lib/main.dart': before};
    },
    createCandidateHost: () => host,
  );
}

class _RequestFixtureHome extends StatefulWidget {
  const _RequestFixtureHome(this.fixture);
  final RequestHistoryFixture fixture;
  @override
  State<_RequestFixtureHome> createState() => _RequestFixtureHomeState();
}

class _RequestFixtureHomeState extends State<_RequestFixtureHome> {
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Initial request history UI fixture')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Supplied in-memory fixture: four request outcomes are seeded without transport. '
          'Explicit production requests use a deterministic supplied provider and source capture, never HTTP, MLX, SDK, files or preview. '
          'Reopening is read-only. This is not live inference evidence.',
        ),
        Text(
          'Original non-journal records unchanged: ${widget.fixture.originalsUnchanged}',
        ),
        Text('Journal commits after setup: ${widget.fixture.records.commits}'),
        Text(
          'Supplied provider creations: ${widget.fixture.providerCreations}',
        ),
        Text('Supplied source captures: ${widget.fixture.sourceCaptures}'),
        Text('Unexpected writes: ${widget.fixture.records.unexpectedWrites}'),
        Text('SDK/preview attempts: ${widget.fixture.host.effectAttempts}'),
        Text('Explicit fixture controls: ${widget.fixture.fixtureControls}'),
        FilledButton(
          onPressed: () async {
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) =>
                    SourceReviewScreen(controller: widget.fixture.controller()),
              ),
            );
            if (mounted) setState(() {});
          },
          child: const Text('Open initial request history fixture'),
        ),
        OutlinedButton(
          onPressed: () {
            setState(() {
              widget.fixture.failCleanup = !widget.fixture.failCleanup;
              widget.fixture.fixtureControls++;
            });
          },
          child: Text(
            'Supplied cleanup failure: ${widget.fixture.failCleanup}',
          ),
        ),
        OutlinedButton(
          onPressed: () {
            setState(() {
              widget.fixture.records.failOutcome =
                  !widget.fixture.records.failOutcome;
              widget.fixture.fixtureControls++;
            });
          },
          child: Text(
            'Supplied outcome-write failure: ${widget.fixture.records.failOutcome}',
          ),
        ),
        OutlinedButton(
          onPressed: () {
            setState(() {
              widget.fixture.records.failRead =
                  !widget.fixture.records.failRead;
              widget.fixture.fixtureControls++;
            });
          },
          child: Text(
            'Supplied history read failure: ${widget.fixture.records.failRead}',
          ),
        ),
        OutlinedButton(
          onPressed: () async {
            await widget.fixture.withdraw();
            if (mounted) setState(() {});
          },
          child: const Text('Withdraw supplied request session'),
        ),
      ],
    ),
  );
}

/// New supplied observations, separate from all historical fixture identities.
Future<Widget> selectedRepairFixtureHome({bool lineageMode = false}) async {
  final supplied = await RequestHistoryFixture.create();
  final records = supplied.records.source..readOnly = false;
  const project = TaskHistoryFixture.project;
  final working = SourceGenerationStore(records).load(project.id)!;
  final failed = working.copy(
    phase: SourceGenerationPhase.failed,
    checkpointVersion: 1,
    outputs: {},
    steps: [
      for (final task in (working.tasks ?? BuildTask.starter).takeWhile(
        (task) => task.operation.name != 'analyze',
      ))
        GenerationStep(
          operation: task.operation.name,
          exitCode: 0,
          output: 'Supplied prerequisite; no SDK ran.',
        ),
      const GenerationStep(
        operation: 'analyze',
        exitCode: 1,
        output: 'Supplied diagnostic; no SDK ran.',
      ),
    ],
  );
  final failure = CandidateVerificationRun(
    number: 1,
    startedAt: DateTime.utc(2026),
    snapshot: failed,
    finished: true,
  );
  await records.setString(
    'studio.sourceCandidate.v1.${project.id}',
    jsonEncode(failed.toJson()),
  );
  await records.setString(
    'studio.candidateChecks.v1.${project.id}',
    jsonEncode(CandidateVerificationJournal([failure]).toJson()),
  );
  final session = AgentSessionStore(
    records,
    project,
  ).load(RequestHistoryFixture.sessionId)!;
  for (final status in [
    RepairAttemptStatus.proposed,
    RepairAttemptStatus.cancelled,
    RepairAttemptStatus.reserved,
  ]) {
    final context = RepairRequestContext.capture(
      records: records,
      project: project,
      failure: failure,
      sessionBinding: AgentSessionBinding.select(
        session: session,
        projectId: project.id,
        boardTaskId: 'Tresolve',
      ),
    );
    final model = ModelRequestProvenance(
      model: lineageMode
          ? 'supplied-repair-lineage-model'
          : 'supplied-repair-history-model',
      outputTokens: 4096,
    );
    final store = RepairAttemptStore(records, project.id);
    await store.reserve(
      failure,
      () {},
      context: context,
      modelRequest: model,
      selectedRequest: SelectedRepairRequestCapture(
        context: context,
        originals: const {'lib/main.dart': RequestHistoryFixture.before},
        modelRequest: model,
      ),
    );
    if (status != RepairAttemptStatus.reserved) {
      await store.finish(
        status,
        authorizeReturn: () {},
        proposal: status == RepairAttemptStatus.proposed
            ? SourceEditProposal.parse(
                {
                  'summary': 'Supplied repair observation',
                  'changes': [
                    {
                      'path': 'lib/main.dart',
                      'before': RequestHistoryFixture.before,
                      'after': RequestHistoryFixture.after,
                    },
                  ],
                },
                originals: const {
                  'lib/main.dart': RequestHistoryFixture.before,
                },
                responseModel: lineageMode
                    ? 'supplied-repair-lineage-model'
                    : 'supplied-repair-history-response',
              )
            : null,
      );
    }
  }
  if (lineageMode) {
    // Discard only inherited disposable run2 samples in this new fixture mode.
    for (final key in [
      'studio.candidateReopen.v1.${project.id}.2',
      'studio.agentTaskHistory.v1.${project.id}.2',
      'studio.agentExecution.v1.candidate-${project.id}-2',
    ]) {
      records.values.remove(key);
    }
    final attempt = RepairAttemptStore(
      records,
      project.id,
    ).load().attempts.first;
    final origin = SelectedRepairRequest.decode(
      records.getString(
        '${SelectedRepairRequest.prefix}${project.id}.${attempt.number}',
      )!,
    );
    final reference = SelectedRepairRequestReference.forProposed(
      origin,
      attempt,
    );
    final proposal = SourceEditProposal.parse(
      {
        'summary': attempt.proposal!.summary,
        'changes': [
          for (final c in attempt.proposal!.changes)
            {'path': c.path, 'before': c.before, 'after': c.after},
        ],
      },
      originals: const {'lib/main.dart': RequestHistoryFixture.before},
      responseModel: attempt.modelRequest!.responseModel,
    );
    final evidence = ApprovedSourceProposal(
      projectId: project.id,
      boardTaskId: 'Tresolve',
      approval: working.approval!,
      proposal: proposal,
      modelRequest: attempt.modelRequest,
      repairRequestReference: reference,
    );
    final prepared = GeneratedProject.fromJson({
      ...working
          .copy(
            phase: SourceGenerationPhase.generated,
            steps: [],
            outputs: {},
            resolution: {},
            checkpointVersion: 0,
            pendingOperation: '',
            failedOperation: '',
          )
          .toJson(),
      'directory': '/fixture/repair-lineage-copy',
      'sourceRequest': attempt.modelRequest!.toJson(),
      'sources': {
        ...working.sources,
        'lib/main.dart': SelectedRepairRequest.fingerprint(
          RequestHistoryFixture.after,
        ),
      },
    });
    final basis = CandidateReopenBasis.capture(
      projectId: project.id,
      workingRecord: records.getString('studio.generation.v1.${project.id}')!,
      working: working,
      sourceBase: failed,
      prepared: prepared,
      evidence: evidence,
    );
    await CandidateVerificationStore(records, project.id).start(
      prepared.copy(phase: SourceGenerationPhase.verifying),
      () {},
      reopenBasis: basis,
      repairRequestReference: reference,
      sessionAdmission: AgentSessionRunAdmission(
        records,
        project,
        AgentSessionBinding.select(
          session: session,
          projectId: project.id,
          boardTaskId: 'Tresolve',
        ),
      ),
    );
  }
  records.readOnly = true;
  records.writeAttempts = 0;
  final baseline = jsonEncode(records.values);
  final host = ReopenFixtureHost();
  var captures = 0, providers = 0;
  return StatefulBuilder(
    builder: (context, refresh) => Scaffold(
      appBar: AppBar(
        title: Text(
          lineageMode
              ? 'Repair candidate lineage UI fixture'
              : 'Selected repair provenance UI fixture',
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (lineageMode)
            const Text(
              'New supplied linked startup only. No model, source copy, SDK or preview ran. Open and reload must preserve every record.',
            ),
          const Text(
            'Three supplied repair observations: proposed, cancelled locally, '
            'and unresolved. Requested task Tresolve differs from failed operation analyze. '
            'No live inference, source capture, SDK or preview ran. Historical fixture identities are unchanged.',
          ),
          Text(
            'Writes after setup: ${records.writeAttempts} · Captures: $captures · '
            'Providers: $providers · Inspections: ${host.inspections} · Tools: ${host.effectAttempts}',
          ),
          Text('Records unchanged: ${baseline == jsonEncode(records.values)}'),
          OutlinedButton(
            onPressed: () async {
              if (lineageMode) {
                final controller = AgentSessionController(
                  AgentSessionStore(records, project),
                  createRecoveryHost: () => host,
                )..load();
                controller.open(RequestHistoryFixture.sessionId);
                await Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => AgentSessionScreen(
                      controller: controller,
                      projectName:
                          'Supplied repair lineage — production screen',
                    ),
                  ),
                );
                controller.dispose();
                if (context.mounted) refresh(() {});
                return;
              }
              final controller = SourceReviewController(
                project: project,
                generated: working,
                records: records,
                selectedSession: session,
                readSnapshot: (_, _) async {
                  captures++;
                  throw StateError('No source capture supplied.');
                },
                proposer: ApprovedSourceProposer(
                  records,
                  proposer: SourceEditProposer(
                    createProvider: (_) {
                      providers++;
                      throw StateError('No provider supplied.');
                    },
                  ),
                ),
                createCandidateHost: () => host,
              );
              await Navigator.of(context).push<void>(
                MaterialPageRoute(
                  builder: (_) => SourceReviewScreen(controller: controller),
                ),
              );
              controller.dispose();
              if (context.mounted) refresh(() {});
            },
            child: Text(
              lineageMode
                  ? 'Open repair candidate lineage'
                  : 'Open selected repair history',
            ),
          ),
        ],
      ),
    ),
  );
}
