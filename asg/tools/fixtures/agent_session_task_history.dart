// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:flutter/material.dart';

import 'package:asg/controllers/agent_session_controller.dart';
import 'package:asg/models/agent_session_binding.dart';
import 'package:asg/models/build_plan.dart';
import 'package:asg/models/chat_message.dart';
import 'package:asg/models/project.dart';
import 'package:asg/models/requirements_board.dart';
import 'package:asg/models/source_generation.dart';
import 'package:asg/services/agent_session_admission.dart';
import 'package:asg/services/agent_session_store.dart';
import 'package:asg/services/candidate_verification_store.dart';
import 'package:asg/services/conversation_store.dart';
import 'package:asg/services/plan_approval_store.dart';
import 'package:asg/services/record_storage.dart';
import 'package:asg/services/requirements_store.dart';
import 'package:asg/services/studio_database.dart';
import 'package:asg/services/studio_store.dart';
import 'package:asg/views/agent_session_screen.dart';

/// Explicit in-memory UI fixture. No host, model, file or command is invoked.
class TaskHistoryFixtureRecords implements ConditionalRecordStorage {
  final Map<String, String> values = {};
  bool readOnly = false;
  int writeAttempts = 0;
  @override
  String? getString(String key) => values[key];
  void _requireWrite() {
    if (readOnly) {
      writeAttempts++;
      throw StateError('Fixture records are read-only after setup.');
    }
  }

  @override
  Future<bool> setString(String key, String value) async {
    _requireWrite();
    StudioDatabase.validate(key, value);
    values[key] = value;
    return true;
  }

  @override
  Future<void> commitRecords({
    required Map<String, String?> expected,
    required Map<String, String> updates,
    required void Function() authorize,
  }) async {
    _requireWrite();
    if (expected.entries.any((item) => values[item.key] != item.value)) {
      throw StateError('Fixture CAS refused.');
    }
    authorize();
    for (final item in updates.entries) {
      StudioDatabase.validate(item.key, item.value);
    }
    values.addAll(updates);
  }
}

class TaskHistoryFixture {
  TaskHistoryFixture._(this.records, this.baseline);
  static const project = StudioProject(
    id: 'history-fixture',
    name: 'Deterministic task-history fixture',
    description: 'Read-only UI observations; no tools or inference run.',
    type: 'Flutter',
    platforms: ['Web'],
    location: '',
  );
  final TaskHistoryFixtureRecords records;
  final String baseline;
  bool get unchanged => jsonEncode(records.values) == baseline;

  static Future<TaskHistoryFixture> create() async {
    final records = TaskHistoryFixtureRecords();
    await StudioStore(records).save([project]);
    final operations = ['resolve', 'test', 'analyze', 'build'];
    final dependencies = <String, List<String>>{
      'resolve': [],
      'test': ['resolve'],
      'analyze': ['resolve'],
      'build': ['test', 'analyze'],
    };
    final board = RequirementsBoard(
      requirements: [
        ProjectRequirement(
          id: 'R1',
          title: 'Fixture workflow',
          acceptance: 'Inspect saved observations',
        ),
      ],
      tasks: [
        for (final operation in operations)
          DevelopmentTask(
            id: 'T$operation',
            requirementId: 'R1',
            title: operation,
            dependencies: dependencies[operation]!
                .map((item) => 'T$item')
                .toList(),
          ),
      ],
    );
    final requirements = RequirementsStore(records);
    await requirements.save(project.id, requirements.load(project.id), board);
    final content =
        '```asg-build\n${jsonEncode({
          'version': 3,
          'adapter': 'flutter-starter',
          'tasks': [
            for (final operation in operations) {'id': operation, 'operation': operation, 'boardTaskId': 'T$operation', 'dependencies': dependencies[operation]},
          ],
        })}\n```';
    final approvals = PlanApprovalStore(records);
    final messages = [
      ChatMessage(
        role: 'assistant',
        content: content,
        planContext: approvals.contextFor(project),
      ),
    ];
    await ConversationStore(records).save(project.id, messages);
    await approvals.save(project, messages, true);
    final approval = approvals.requireCurrentApproval(project);
    final snapshot = GeneratedProject(
      directory: '/fixture-only',
      sdk: '/fixture-no-sdk',
      python: 'fixture-no-process',
      sources: {'lib/main.dart': 'a' * 64},
      confined: true,
      approval: approval,
      tasks: BuildPlan.parse(
        content,
        board: requirements.load(project.id),
      ).tasks,
      phase: SourceGenerationPhase.verifying,
      checkpointVersion: 1,
      pendingOperation: 'resolve',
    );
    final sessions = AgentSessionStore(records, project);
    for (final id in ['unknown', 'late-result', 'legacy']) {
      var selected = await sessions.create(
        id,
        board.tasks.map((item) => item.id).toList(),
      );
      final store = CandidateVerificationStore(records, project.id);
      final run = await store.start(
        snapshot,
        () {},
        sessionAdmission: id == 'legacy'
            ? null
            : AgentSessionRunAdmission(
                records,
                project,
                AgentSessionBinding.select(
                  session: selected,
                  projectId: project.id,
                  boardTaskId: 'Tresolve',
                ),
              ),
      );
      if (id == 'legacy') {
        selected = await sessions.observeRun(selected, 'Tresolve', run);
      }
      final resolved = snapshot.copy(
        pendingOperation: '',
        steps: [
          const GenerationStep(
            operation: 'resolve',
            exitCode: 0,
            output: 'fixture-result-private',
          ),
        ],
      );
      await store.checkpoint(resolved, () {});
      final pending = resolved.copy(pendingOperation: 'test');
      await store.checkpoint(pending, () {});
      await sessions.requestCancellation(
        id == 'legacy' ? selected : store.admittedSession!,
      );
      final unknown = id != 'late-result';
      final last = unknown
          ? pending.copy(
              phase: SourceGenerationPhase.failed,
              failedOperation: 'test',
            )
          : resolved.copy(
              phase: SourceGenerationPhase.failed,
              steps: [
                ...resolved.steps,
                const GenerationStep(
                  operation: 'test',
                  exitCode: 0,
                  output: 'fixture-result-private',
                ),
              ],
            );
      await store.checkpoint(last, () {}, finished: !unknown);
      if (unknown) {
        await store.acknowledgeStopped(store.load().runs.last, () {});
      }
    }
    records.readOnly = true;
    return TaskHistoryFixture._(records, jsonEncode(records.values));
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final fixture = await TaskHistoryFixture.create();
  runApp(MaterialApp(home: _FixtureHome(fixture)));
}

class _FixtureHome extends StatefulWidget {
  const _FixtureHome(this.fixture);
  final TaskHistoryFixture fixture;
  @override
  State<_FixtureHome> createState() => _FixtureHomeState();
}

class _FixtureHomeState extends State<_FixtureHome> {
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Task-history UI fixture')),
    body: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Deterministic in-memory data. No tools or inference run.',
          ),
          Text(
            'Write attempts after setup: ${widget.fixture.records.writeAttempts}',
          ),
          Text('Records unchanged: ${widget.fixture.unchanged}'),
          FilledButton(
            onPressed: () async {
              await Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => AgentSessionScreen(
                    controller: AgentSessionController(
                      AgentSessionStore(
                        widget.fixture.records,
                        TaskHistoryFixture.project,
                      ),
                    ),
                    projectName: TaskHistoryFixture.project.name,
                  ),
                ),
              );
              if (mounted) setState(() {});
            },
            child: const Text('Open saved-session fixture'),
          ),
        ],
      ),
    ),
  );
}
