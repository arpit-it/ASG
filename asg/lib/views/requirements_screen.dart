// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/requirements_controller.dart';
import '../models/requirements_board.dart';

class RequirementsScreen extends StatefulWidget {
  const RequirementsScreen({
    super.key,
    required this.controller,
    required this.projectName,
    this.onCheckReport,
  });
  final RequirementsController controller;
  final String projectName;
  final VoidCallback? onCheckReport;
  @override
  State<RequirementsScreen> createState() => _RequirementsScreenState();
}

class _RequirementsScreenState extends State<RequirementsScreen> {
  RequirementsController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    controller.load();
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  Future<void> editRequirement([ProjectRequirement? original]) =>
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => _BoardEditor(
          controller: controller,
          requirement: original,
          taskEditor: false,
        ),
      );
  Future<void> editTask([DevelopmentTask? original]) => showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) =>
        _BoardEditor(controller: controller, task: original, taskEditor: true),
  );
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) {
      final board = controller.board;
      return PopScope(
        canPop: !controller.busy,
        child: Scaffold(
          appBar: AppBar(title: const Text('Requirements and tasks')),
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Record acceptance criteria, then track the work needed to meet them. Changes invalidate saved plan approval. Task completion is a manual progress record, not verified test evidence.',
              ),
              if (controller.error != null)
                SelectableText(
                  controller.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              if (board == null)
                TextButton(
                  onPressed: controller.load,
                  child: const Text('Retry loading'),
                ),
              if (board != null) ...[
                Text(
                  'Revision ${board.revision} · ${board.tasks.where((t) => t.status == TaskStatus.done).length}/${board.tasks.length} tasks complete',
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    FilledButton(
                      onPressed: controller.busy
                          ? null
                          : () => editRequirement(),
                      child: const Text('Add requirement'),
                    ),
                    OutlinedButton(
                      onPressed: controller.busy || board.requirements.isEmpty
                          ? null
                          : () => editTask(),
                      child: const Text('Add task'),
                    ),
                    if (widget.onCheckReport != null)
                      OutlinedButton(
                        onPressed: controller.busy
                            ? null
                            : widget.onCheckReport,
                        child: const Text('Requirement check report'),
                      ),
                    TextButton(
                      onPressed: () => showDialog<void>(
                        context: context,
                        builder: (_) => AlertDialog(
                          title: const Text('Project requirements document'),
                          content: SizedBox(
                            width: 640,
                            child: SingleChildScrollView(
                              child: SelectableText(
                                board.document(widget.projectName),
                              ),
                            ),
                          ),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(context),
                              child: const Text('Close'),
                            ),
                          ],
                        ),
                      ),
                      child: const Text('Read document'),
                    ),
                  ],
                ),
                if (board.requirements.isEmpty)
                  const Text('No structured requirements yet.'),
                for (final r in board.requirements)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${r.id}: ${r.title}',
                            style: Theme.of(context).textTheme.titleMedium,
                          ),
                          Text('Acceptance: ${r.acceptance}'),
                          TextButton(
                            onPressed: controller.busy
                                ? null
                                : () => editRequirement(r),
                            child: Text('Edit ${r.id}'),
                          ),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 16),
                Text(
                  'Development tasks',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                for (final t in board.tasks)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('${t.id}: ${t.title}'),
                          Text('${t.requirementId} · ${t.status.name}'),
                          Text(
                            'Dependencies: ${t.dependencies.isEmpty ? 'none' : t.dependencies.join(', ')}',
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              TextButton(
                                onPressed: controller.busy
                                    ? null
                                    : () => editTask(t),
                                child: Text('Edit ${t.id}'),
                              ),
                              if (t.status != TaskStatus.queued)
                                TextButton(
                                  onPressed: controller.busy
                                      ? null
                                      : () => controller.saveTask(
                                          t.withStatus(TaskStatus.queued),
                                          editing: true,
                                        ),
                                  child: Text('Reopen ${t.id}'),
                                ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      );
    },
  );
}

class _BoardEditor extends StatefulWidget {
  const _BoardEditor({
    required this.controller,
    required this.taskEditor,
    this.requirement,
    this.task,
  });
  final RequirementsController controller;
  final bool taskEditor;
  final ProjectRequirement? requirement;
  final DevelopmentTask? task;
  @override
  State<_BoardEditor> createState() => _BoardEditorState();
}

class _BoardEditorState extends State<_BoardEditor> {
  late final id = TextEditingController(
    text: widget.requirement?.id ?? widget.task?.id,
  );
  late final title = TextEditingController(
    text: widget.requirement?.title ?? widget.task?.title,
  );
  late final acceptance = TextEditingController(
    text: widget.requirement?.acceptance,
  );
  late final dependencies = TextEditingController(
    text: widget.task?.dependencies.join(', '),
  );
  late String requirementId =
      widget.task?.requirementId ??
      widget.controller.board!.requirements.firstOrNull?.id ??
      '';
  late TaskStatus status = widget.task?.status ?? TaskStatus.queued;
  @override
  void dispose() {
    id.dispose();
    title.dispose();
    acceptance.dispose();
    dependencies.dispose();
    super.dispose();
  }

  Future<void> save() async {
    final saved = widget.taskEditor
        ? await widget.controller.saveTask(
            DevelopmentTask(
              id: id.text.trim(),
              title: title.text.trim(),
              requirementId: requirementId,
              dependencies: dependencies.text.trim().isEmpty
                  ? []
                  : dependencies.text.split(',').map((s) => s.trim()).toList(),
              status: status,
            ),
            editing: widget.task != null,
          )
        : await widget.controller.saveRequirement(
            ProjectRequirement(
              id: id.text.trim(),
              title: title.text.trim(),
              acceptance: acceptance.text.trim(),
            ),
            editing: widget.requirement != null,
          );
    if (saved && mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final busy = widget.controller.busy;
      return PopScope(
        canPop: !busy,
        child: AlertDialog(
          title: Text(widget.taskEditor ? 'Development task' : 'Requirement'),
          content: SizedBox(
            width: 520,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  TextField(
                    controller: id,
                    enabled:
                        !busy &&
                        widget.requirement == null &&
                        widget.task == null,
                    maxLength: 40,
                    decoration: const InputDecoration(labelText: 'Stable ID'),
                  ),
                  TextField(
                    controller: title,
                    enabled: !busy,
                    maxLength: 200,
                    decoration: const InputDecoration(labelText: 'Title'),
                  ),
                  if (!widget.taskEditor)
                    TextField(
                      controller: acceptance,
                      enabled: !busy,
                      maxLength: 2000,
                      minLines: 3,
                      maxLines: 6,
                      decoration: const InputDecoration(
                        labelText: 'Acceptance criteria',
                      ),
                    ),
                  if (widget.taskEditor) ...[
                    DropdownButtonFormField<String>(
                      initialValue: requirementId,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Requirement',
                      ),
                      items: [
                        for (final r in widget.controller.board!.requirements)
                          DropdownMenuItem(value: r.id, child: Text(r.id)),
                      ],
                      onChanged: busy
                          ? null
                          : (value) => setState(() => requirementId = value!),
                    ),
                    TextField(
                      controller: dependencies,
                      enabled: !busy,
                      decoration: const InputDecoration(
                        labelText: 'Dependency task IDs (comma separated)',
                      ),
                    ),
                    DropdownButtonFormField<TaskStatus>(
                      initialValue: status,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Status'),
                      items: [
                        for (final s in TaskStatus.values)
                          DropdownMenuItem(value: s, child: Text(s.name)),
                      ],
                      onChanged: busy
                          ? null
                          : (value) => setState(() => status = value!),
                    ),
                  ],
                  if (widget.controller.error != null)
                    SelectableText(
                      widget.controller.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: busy ? null : () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: busy ? null : save,
              child: Text(busy ? 'Saving…' : 'Save'),
            ),
          ],
        ),
      );
    },
  );
}
