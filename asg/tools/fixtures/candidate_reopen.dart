// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:asg/controllers/agent_session_controller.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/approved_source_proposal.dart';
import 'package:asg/models/app_definition.dart';
import 'package:asg/models/build_plan.dart';
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

class CandidateReopenFixture {
  CandidateReopenFixture._(this.records, this.baseline);
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

  static Future<CandidateReopenFixture> create() async {
    final old = await TaskHistoryFixture.create();
    final records = old.records..readOnly = false;
    const project = TaskHistoryFixture.project;
    final approval = PlanApprovalStore(records).load(project.id)!;
    final board = RequirementsStore(records).load(project.id);
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
      responseModel: 'fixture-response',
    );
    const request = ModelRequestProvenance(
      model: 'fixture-request',
      outputTokens: 4096,
      responseModel: 'fixture-response',
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
    final journal = CandidateVerificationStore(records, project.id);
    final run = await journal.start(
      prepared.copy(phase: SourceGenerationPhase.verifying),
      () {},
      reopenBasis: basis,
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
    records.readOnly = true;
    records.writeAttempts = 0;
    return CandidateReopenFixture._(records, jsonEncode(records.values));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final fixture = await CandidateReopenFixture.create();
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
    appBar: AppBar(title: const Text('Saved-candidate recovery UI fixture')),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        const Text(
          'Deterministic in-memory data and supplied source inspection. No SDK, files, model or preview runs. Records refuse writes after setup.',
        ),
        Text(
          'Write attempts after setup: ${widget.fixture.records.writeAttempts}',
        ),
        Text('Records unchanged: ${widget.fixture.unchanged}'),
        Text('Supplied source inspections: ${widget.fixture.inspections}'),
        Text(
          'Command/model/preview attempts: ${widget.fixture.effectAttempts}',
        ),
        FilledButton(
          onPressed: () async {
            final controller = AgentSessionController(
              AgentSessionStore(
                widget.fixture.records,
                TaskHistoryFixture.project,
              ),
              createRecoveryHost: widget.fixture.createHost,
            );
            controller.load();
            controller.open('recoverable');
            await Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => AgentSessionScreen(
                  controller: controller,
                  projectName: 'Recovery fixture — production screens',
                ),
              ),
            );
            if (mounted) setState(() {});
          },
          child: const Text('Open saved-session recovery fixture'),
        ),
      ],
    ),
  );
}
