// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/agent_session_controller.dart';

class AgentSessionScreen extends StatefulWidget {
  const AgentSessionScreen({
    super.key,
    required this.controller,
    required this.projectName,
  });
  final AgentSessionController controller;
  final String projectName;
  @override
  State<AgentSessionScreen> createState() => _AgentSessionScreenState();
}

class _AgentSessionScreenState extends State<AgentSessionScreen> {
  final _sessionId = TextEditingController();
  bool _consent = false;
  AgentSessionController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    controller.load();
  }

  @override
  void dispose() {
    _sessionId.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final selected = controller.selected;
      return PopScope(
        canPop: !controller.busy,
        child: Scaffold(
          appBar: AppBar(
            title: const Text('Saved work sessions'),
            actions: [
              IconButton(
                tooltip: 'Reload sessions',
                onPressed: controller.busy
                    ? null
                    : () {
                        setState(() => _consent = false);
                        controller.load();
                      },
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                widget.projectName,
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const Text(
                'Save an approved task selection and review its recorded history. This screen does not start or resume commands.',
              ),
              if (controller.busy)
                const LinearProgressIndicator(semanticsLabel: 'Saving session'),
              if (controller.error case final error?)
                Semantics(liveRegion: true, child: Text(error)),
              if (controller.historyError case final error?)
                Semantics(liveRegion: true, child: Text(error)),
              if (controller.approvalError case final error?) Text(error),
              if (controller.sessionLimitReached)
                const Text(
                  'This project has reached the saved-session limit of 128. Existing sessions remain available.',
                ),
              if (controller.tasks.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Approved tasks',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Text(
                  'Prerequisites are selected together. Removing a prerequisite also removes its dependent tasks.',
                ),
                for (final task in controller.tasks)
                  CheckboxListTile(
                    title: Text('${task.title} (${task.id})'),
                    value: controller.selectedTaskIds.contains(task.id),
                    onChanged: controller.busy
                        ? null
                        : (value) {
                            setState(() => _consent = false);
                            controller.toggleTask(task.id, value == true);
                          },
                  ),
                CheckboxListTile(
                  title: const Text(
                    'Save this selection for the approved Plan',
                  ),
                  value: _consent,
                  onChanged: controller.busy
                      ? null
                      : (value) => setState(() => _consent = value == true),
                ),
                FilledButton(
                  onPressed: controller.canCreate && _consent
                      ? () async {
                          if (await controller.create(approved: _consent) &&
                              mounted) {
                            setState(() => _consent = false);
                          }
                        }
                      : null,
                  child: const Text('Create saved session'),
                ),
              ],
              const SizedBox(height: 24),
              Text(
                'Session history',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (controller.sessions.isEmpty &&
                  controller.historyError == null)
                const Text('No saved sessions in this list yet.'),
              for (final session in controller.sessions)
                OutlinedButton(
                  onPressed: controller.busy
                      ? null
                      : () => controller.open(session.sessionId),
                  child: Text(
                    'Open ${session.sessionId}${session.cancellationRequested ? ' — cancellation requested' : ''}',
                  ),
                ),
              for (final id in controller.unavailableIds)
                Text(
                  'Session $id is unavailable. Its saved data has not been replaced.',
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _sessionId,
                enabled: !controller.busy,
                decoration: const InputDecoration(
                  labelText: 'Session ID',
                  helperText: 'Open older sessions that are not in the list.',
                  helperMaxLines: 3,
                ),
              ),
              OutlinedButton(
                onPressed: controller.busy
                    ? null
                    : () => controller.open(_sessionId.text),
                child: const Text('Open by ID'),
              ),
              if (selected != null) ...[
                const Divider(height: 32),
                Text(
                  'Selected session',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                SelectableText('ID: ${selected.sessionId}'),
                Text(
                  selected.cancellationRequested
                      ? 'Cancellation requested'
                      : 'Saved for review',
                ),
                Text(
                  '${selected.tasks.items.length} selected tasks; ${selected.dispatches.length} recorded run references.',
                ),
                const Text(
                  'Saved references do not prove task completion or command exit. Reopening starts no work.',
                ),
                for (final task in selected.tasks.items)
                  Text('${task.id} (${task.requirementId})'),
                if (selected.dispatches.isEmpty)
                  const Text('No recorded runs for this session.'),
                for (final status in controller.runStatuses)
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      'Run ${status.reference.runNumber} — ${status.reference.boardTaskId}',
                    ),
                    subtitle: status.available
                        ? Text(
                            'Recorded candidate: ${status.sourcePhase!.name}; checkpoint: ${status.executionPhase!.name}. '
                            '${status.pendingOperation?.isNotEmpty == true ? 'Unresolved operation: ${status.pendingOperation}. Its outcome is unknown.' : 'No unresolved operation is recorded.'}',
                          )
                        : const Text(
                            'Run evidence is unavailable or does not match this session. Saved data is retained.',
                          ),
                  ),
                if (selected.dispatches.isNotEmpty)
                  const Text(
                    'These are saved observations, not live process status or proof that a selected task completed.',
                  ),
                if (controller.canRemember)
                  OutlinedButton(
                    onPressed: controller.rememberSelected,
                    child: const Text('Add session to list'),
                  ),
                FilledButton(
                  onPressed: controller.busy || selected.cancellationRequested
                      ? null
                      : () {
                          final value = controller.selectForSourceReview();
                          if (value != null) Navigator.of(context).pop(value);
                        },
                  child: const Text('Use session for source review'),
                ),
                const Text(
                  'Requesting cancellation records your intent. It does not confirm that any running process has stopped.',
                ),
                FilledButton.tonal(
                  onPressed: controller.busy || selected.cancellationRequested
                      ? null
                      : controller.requestCancellation,
                  child: const Text('Request session cancellation'),
                ),
              ],
            ],
          ),
        ),
      );
    },
  );
}
