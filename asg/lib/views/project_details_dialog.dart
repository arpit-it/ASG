// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/project_details_controller.dart';

/// Owns the supplied controller for the lifetime of this dialog.
class ProjectDetailsDialog extends StatefulWidget {
  const ProjectDetailsDialog({super.key, required this.controller});
  final ProjectDetailsController controller;
  @override
  State<ProjectDetailsDialog> createState() => _ProjectDetailsDialogState();
}

class _ProjectDetailsDialogState extends State<ProjectDetailsDialog> {
  ProjectDetailsController get controller => widget.controller;
  late final name = TextEditingController(text: controller.project.name);
  late final requirements = TextEditingController(
    text: controller.project.description,
  );
  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  Future<void> save() async {
    final saved = await controller.save(name.text, requirements.text);
    if (saved && mounted) Navigator.of(context).pop(controller.project);
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    controller.dispose();
    name.dispose();
    requirements.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !controller.busy,
    child: AlertDialog(
      title: const Text('Project details'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Update the name and requirements used for future source exports. To change the running app, use chat. Your current app and conversation are preserved.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: name,
                enabled: !controller.busy,
                decoration: const InputDecoration(labelText: 'Project name'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: requirements,
                enabled: !controller.busy,
                minLines: 5,
                maxLines: 12,
                decoration: const InputDecoration(labelText: 'Requirements'),
              ),
              if (controller.error != null) ...[
                const SizedBox(height: 12),
                Text(
                  controller.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ],
              if (controller.busy) const LinearProgressIndicator(),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: controller.busy ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: controller.busy ? null : save,
          child: const Text('Save details'),
        ),
      ],
    ),
  );
}
