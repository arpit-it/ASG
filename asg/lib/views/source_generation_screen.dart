// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'generation_capability_panel.dart';

import 'package:flutter/material.dart';

import '../controllers/source_generation_controller.dart';
import '../models/source_generation.dart';
import '../models/generation_toolchain.dart';
import '../models/build_history_entry.dart';
import '../services/folder_picker.dart';
import 'board_verification_progress.dart';
import 'source_review_screen.dart';

class SourceGenerationScreen extends StatefulWidget {
  const SourceGenerationScreen({
    super.key,
    required this.controller,
    this.picker,
  });
  final SourceGenerationController controller;
  final FolderPicker? picker;
  @override
  State<SourceGenerationScreen> createState() => _SourceGenerationScreenState();
}

class _SourceGenerationScreenState extends State<SourceGenerationScreen> {
  final parent = TextEditingController(),
      name = TextEditingController(text: 'generated_app');
  late final sdk = TextEditingController(text: controller.result?.sdk ?? '');
  late final python = TextEditingController(text: controller.initialPython);
  bool approved = false;
  SourceGenerationController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
    sdk.addListener(controller.invalidateToolchain);
    python.addListener(controller.invalidateToolchain);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    controller.dispose();
    for (final input in [parent, sdk, name, python]) {
      input.dispose();
    }
    super.dispose();
  }

  Future<void> pick(TextEditingController target) async {
    final selected = await controller.chooseDirectory(
      widget.picker ?? FolderPicker(),
    );
    if (mounted && selected != null) setState(() => target.text = selected);
  }

  Future<void> selectRollback(BuildHistoryEntry entry) async {
    final working = controller.result;
    if (working == null || !controller.canRollback(entry)) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Restore selected working build?'),
        content: SingleChildScrollView(
          child: Text(
            'Selected version: ${entry.recordedAt?.toLocal() ?? 'timestamp unknown'}\n'
            '${entry.project.directory}\n\n'
            'Current work retained: ${working.directory}\n\n'
            'Switch the working build and preview to the selected existing files. '
            'Files must still match their saved verification. No files, prototype, '
            'requirements or approvals are overwritten; no build commands run. '
            'The displaced working record and full history are retained. '
            'An earlier build may differ from your current inputs.',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Restore selected build'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    await controller.rollback(entry, expectedWorking: working, confirmed: true);
  }

  Widget directory(TextEditingController input, String label) => Row(
    children: [
      Expanded(
        child: TextField(
          controller: input,
          enabled: !controller.busy && controller.available,
          decoration: InputDecoration(labelText: label),
        ),
      ),
      IconButton(
        tooltip: 'Choose $label',
        onPressed: controller.busy || !controller.available
            ? null
            : () => pick(input),
        icon: const Icon(Icons.folder_open),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final result = controller.result;
    final List<BuildHistoryEntry> history = result == null
        ? const []
        : controller.buildHistory;
    final snapshotStatus = controller.snapshotStatus;
    final previewLabel = switch (snapshotStatus) {
      GeneratedSnapshotStatus.outdated => 'Preview earlier generated build',
      GeneratedSnapshotStatus.unknown => 'Preview saved build (inputs unknown)',
      _ => 'Start actual built preview',
    };
    final openLabel = switch (snapshotStatus) {
      GeneratedSnapshotStatus.outdated => 'Open earlier build in browser',
      GeneratedSnapshotStatus.unknown => 'Open saved build in browser',
      _ => 'Open generated app in browser',
    };
    return PopScope(
      canPop: !controller.busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Generate Flutter app')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Create an independent Flutter web application',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 12),
            Text(
              'Use the current saved prototype and reviewed requirements for ${controller.project.name}. A fixed MVC starter is written to a NEW folder, then checked, tested and built. This does not generate arbitrary model-written source or replace an existing app.',
            ),
            const SizedBox(height: 12),
            ExpansionTile(
              title: const Text('Review generation input'),
              children: [
                SelectableText(controller.project.description),
                Text(
                  'Requested platforms: ${controller.project.platforms.join(', ')}. This starter exports Flutter web only.',
                ),
                Text(
                  'Current app: ${controller.definition.title} • ${controller.definition.theme}',
                ),
                for (final element in controller.definition.elements)
                  ListTile(
                    title: Text(element.label),
                    subtitle: Text(element.kind.name),
                  ),
              ],
            ),
            GenerationCapabilityPanel(report: controller.capabilities),
            if (!controller.available)
              const Text(
                'Generation currently requires the macOS app, Flutter project type and readable history. Other platforms retain the in-app prototype.',
              ),
            ExpansionTile(
              title: const Text('Saved plan and Build authorization'),
              children: [SelectableText(controller.planStatus)],
            ),
            const Text(
              'Build requires a current saved Plan approval in addition to the operation consent below. Return to the workspace and open Plan to draft, review or withdraw approval. Withdrawal prevents subsequent starts; it does not cancel a command already running.',
            ),
            const Text(
              'Starter verification always includes resolve, analyze, test and build. The validated saved Plan sets task IDs, dependencies and sequential order. These tasks verify the starter; they do not implement arbitrary Plan prose.',
            ),
            directory(parent, 'Existing parent directory'),
            TextField(
              controller: name,
              enabled: !controller.busy && controller.available,
              decoration: const InputDecoration(
                labelText: 'New folder name (lowercase_with_underscores)',
              ),
            ),
            directory(sdk, 'Installed Flutter SDK directory'),
            TextField(
              controller: python,
              enabled: !controller.busy && controller.available,
              decoration: const InputDecoration(
                labelText: 'Installed Python 3 executable',
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: controller.busy || !controller.available
                  ? null
                  : () => controller.inspectToolchain(
                      sdk.text.trim(),
                      python.text.trim(),
                    ),
              icon: const Icon(Icons.find_in_page_outlined),
              label: const Text('Inspect toolchain paths'),
            ),
            if (controller.toolchain case final report?) ...[
              Text('Flutter: ${report.flutter}'),
              Text('Dart: ${report.dart}'),
              Text('Python: ${report.python}'),
              const Text(GenerationToolchain.limits),
            ],
            const Text(
              'Approved operations: offline dependency resolution, Flutter analysis, tests, web build, and an optional loopback preview. At most four commands run, each with a 3-minute deadline and a 64 KiB combined output limit. These fixed limits are saved with verification evidence. Missing cached SDK packages cause a failure; no package/model installation is performed. These trusted tools run with your host permissions, not in a security sandbox.',
            ),
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'I approve creating this new project and running the listed verification steps',
              ),
              value: approved,
              onChanged: controller.busy
                  ? null
                  : (value) => setState(() => approved = value ?? false),
            ),
            FilledButton.icon(
              onPressed: controller.busy || !controller.available || !approved
                  ? null
                  : () => controller.generate(
                      parent: parent.text.trim(),
                      name: name.text.trim(),
                      sdk: sdk.text.trim(),
                      python: python.text.trim(),
                      approved: approved,
                    ),
              icon: const Icon(Icons.code),
              label: const Text('Generate, test and build'),
            ),
            if (controller.busy) ...[
              const SizedBox(height: 16),
              const LinearProgressIndicator(),
              const Text(
                'Working… saved outcomes appear below. Keep this screen open.',
              ),
            ],
            if (controller.verifying) ...[
              OutlinedButton.icon(
                onPressed: controller.stopRequested
                    ? null
                    : controller.stopVerification,
                icon: const Icon(Icons.stop),
                label: Text(
                  controller.stopRequested
                      ? 'Stopping verification…'
                      : 'Stop verification',
                ),
              ),
              const Text(
                'Stop requests termination of the current command and prevents later commands. Existing files and completed results are retained. Wait for the saved outcome before retrying.',
              ),
            ],
            if (controller.error != null)
              SelectableText(
                controller.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (result != null) ...[
              const Divider(height: 32),
              Text(
                'Saved outcome: ${result.phase.name}',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              SelectableText(result.directory),
              OutlinedButton(
                onPressed: controller.busy || !controller.available
                    ? null
                    : () {
                        final review = controller.createSourceReview();
                        if (review == null) return;
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                SourceReviewScreen(controller: review),
                          ),
                        );
                      },
                child: const Text('Review model source proposal'),
              ),
              Text(
                result.approval == null
                    ? 'Legacy outcome: authorizing plan is unknown. Generate a new folder to bind a current approval before retrying verification.'
                    : 'Authorizing Plan: message ${result.approval!.messageIndex + 1}, approved ${result.approval!.recordedAt.toUtc().toIso8601String()}. Retry requires this exact approval and matching inputs.',
              ),
              if (result.approval != null)
                ExpansionTile(
                  title: const Text('Plan that authorized this build'),
                  children: [SelectableText(result.approval!.content)],
                ),
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(switch (snapshotStatus) {
                  GeneratedSnapshotStatus.current => 'This snapshot matches the current application and project details.',
                  GeneratedSnapshotStatus.outdated => 'Earlier snapshot: current application or project details have changed. Generate a new folder to include those changes.',
                  GeneratedSnapshotStatus.unknown => 'Snapshot inputs cannot be identified from this saved record. Generate a new folder to capture the current inputs.',
                  GeneratedSnapshotStatus.none => '',
                }, key: const ValueKey('generatedSnapshotStatus')),
              ),
              if (result.phase == SourceGenerationPhase.verifying &&
                  !controller.busy)
                const Text(
                  'The previous run was interrupted. Resume is available only at a confirmed safe boundary; Retry restarts all checks.',
                ),
              if (result.pendingOperation.isNotEmpty && !controller.busy)
                Text(
                  '${result.pendingOperation} was marked for dispatch but has no saved result. '
                  'It may have changed files. Retry restarts all checks; '
                  'resume is blocked.',
                  key: const ValueKey('pendingOperationCheckpoint'),
                ),
              if (result.error.isNotEmpty) Text(result.error),
              if (result.tasks != null) ...[
                BoardVerificationProgress(
                  result: result,
                  active: controller.verifying,
                ),
                const Text('Approved starter task progress'),
                if (result.tasks!.any((task) => task.boardTaskId != null))
                  const Text(
                    'Board links identify planned work. These results do not mark board tasks complete or verify requirement acceptance.',
                  ),
                for (final task in result.tasks!)
                  ListTile(
                    title: Text(
                      '${task.id} (${task.operation.name}): ${result.taskStatus(task, active: controller.verifying).name}',
                    ),
                    subtitle: Text(
                      '${task.boardTaskId == null ? '' : 'Board task: ${task.boardTaskId}. '}'
                      '${task.dependencies.isEmpty ? 'First verification task' : 'Requires ${task.dependencies.join(', ')}'}',
                    ),
                  ),
              ] else
                const Text('Legacy outcome: no saved structured task graph.'),
              for (final step in result.steps)
                ExpansionTile(
                  title: Text(
                    '${step.operation}: ${step.cancelled
                        ? 'cancelled'
                        : step.outputLimitExceeded
                        ? 'output limit exceeded (64 KiB)'
                        : step.timedOut
                        ? 'timed out'
                        : step.exitCode == 0
                        ? 'passed'
                        : 'failed (${step.exitCode})'}',
                  ),
                  children: [SelectableText(step.output)],
                ),
              Text(
                result.resumeRefusal ?? 'Resume keeps completed results and runs only remaining checks with the saved toolchain. Inputs and approval must still match.',
                key: const ValueKey('resumeExplanation'),
              ),
              OutlinedButton(
                onPressed:
                    controller.busy ||
                        result.confined ||
                        !controller.available ||
                        !approved ||
                        result.resumeRefusal != null
                    ? null
                    : () => controller.verifyAgain(
                        approved: approved,
                        resume: true,
                      ),
                child: const Text('Resume remaining checks'),
              ),
              OutlinedButton(
                onPressed:
                    controller.busy ||
                        result.confined ||
                        !controller.available ||
                        !approved
                    ? null
                    : () => controller.verifyAgain(
                        approved: approved,
                        sdk: sdk.text,
                        python: python.text,
                      ),
                child: const Text('Retry verification (unchanged source only)'),
              ),
              if (result.confined)
                const Text(
                  'For further model-source verification, prepare a separate reviewed candidate. The working source and preview are preserved.',
                ),
              if (result.phase == SourceGenerationPhase.ready)
                OutlinedButton(
                  onPressed: controller.busy || !controller.available
                      ? null
                      : controller.startPreview,
                  child: Text(previewLabel),
                ),
            ],
            if (result != null && history.isNotEmpty)
              ExpansionTile(
                title: const Text('Recorded build history'),
                children: [
                  const Text(
                    'Saved evidence only. Artifact availability is unverified until inspected or preview opens. Inspections are point-in-time checks; files can change afterward. History does not restore files or grant execution approval.',
                  ),
                  for (final entry in history.reversed)
                    ExpansionTile(
                      subtitle: Text(
                        controller.artifactInspection(entry)?.label ??
                            'Artifacts not inspected.',
                      ),
                      title: Text(
                        '${entry.recordedAt?.toLocal() ?? 'Legacy outcome · timestamp unknown'} · ${entry.project.phase.name}',
                      ),
                      children: [
                        SelectableText(entry.project.directory),
                        Text(entry.project.sourceRequestDescription),
                        TextButton(
                          onPressed: controller.busy
                              ? null
                              : () => controller.inspectArtifacts(entry),
                          child: const Text('Inspect saved artifacts'),
                        ),
                        OutlinedButton(
                          onPressed: controller.canRollback(entry)
                              ? () => selectRollback(entry)
                              : null,
                          child: const Text('Select for rollback'),
                        ),
                        if (entry.project.phase ==
                                SourceGenerationPhase.ready &&
                            identical(
                              entry,
                              history.lastWhere(
                                (item) =>
                                    item.project.phase ==
                                    SourceGenerationPhase.ready,
                              ),
                            ))
                          const Text('Last recorded successful version'),
                        SelectableText(
                          'Input/source identity: ${entry.project.sources}',
                        ),
                        SelectableText(
                          'Preview artifact identity: ${entry.project.outputs}',
                        ),
                        for (final step in entry.project.steps)
                          ListTile(
                            title: Text(
                              '${step.operation}: exit ${step.exitCode}',
                            ),
                            subtitle: Text(step.output),
                          ),
                      ],
                    ),
                ],
              ),
            if (controller.preview != null) ...[
              const Text(
                'Actual generated build served locally; this is separate from the in-app prototype. The server stops when this screen closes.',
              ),
              SelectableText(controller.preview.toString()),
              FilledButton(
                onPressed: controller.busy || !controller.available
                    ? null
                    : controller.openPreview,
                child: Text(openLabel),
              ),
              TextButton(
                onPressed: controller.busy || !controller.available
                    ? null
                    : controller.stopPreview,
                child: const Text('Stop preview'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
