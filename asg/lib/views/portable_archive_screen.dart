import 'package:flutter/material.dart';

import '../controllers/portable_archive_controller.dart';
import '../models/portable_project_archive.dart';

class PortableArchiveScreen extends StatefulWidget {
  const PortableArchiveScreen({super.key, required this.controller});
  final PortableArchiveController controller;

  @override
  State<PortableArchiveScreen> createState() => _PortableArchiveScreenState();
}

class _PortableArchiveScreenState extends State<PortableArchiveScreen> {
  final backupId = TextEditingController();
  final projectName = TextEditingController();
  PortableArchiveController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    controller.dispose();
    backupId.dispose();
    projectName.dispose();
    super.dispose();
  }

  Widget summary(PortableProjectArchive archive) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '${archive.requirements.requirements.length} requirements · '
        '${archive.requirements.tasks.length} tasks · '
        'board revision ${archive.requirements.revision} · '
        '${archive.messages.length} assistance messages',
      ),
      if (archive.decision case final decision?) ...[
        Text(
          'Historical Plan decision: ${decision.approved ? 'approved' : 'withdrawn'} · ${decision.recordedAt.toIso8601String()}',
        ),
        const Text(
          'Historical information only. This does not grant Build approval.',
        ),
        SelectableText(decision.content),
      ],
      ExpansionTile(
        title: const Text('Review included text'),
        children: [
          for (final requirement in archive.requirements.requirements)
            ListTile(
              title: SelectableText(
                '${requirement.id}: ${requirement.title}\n${requirement.acceptance}',
              ),
            ),
          for (final task in archive.requirements.tasks)
            ListTile(title: SelectableText('${task.id}: ${task.title}')),
          for (final message in archive.messages)
            ListTile(
              title: Text(message.role),
              subtitle: SelectableText(message.content),
            ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !controller.busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('Portable records')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Archives include saved requirements, tasks, board revision and Discuss/Plan/Review conversation text. Version 2 also includes the latest saved Plan decision as historical information only; version 1 remains supported. Prototype edit chat, build history, source files, settings and approval credentials are excluded. Text is verbatim and may contain private information or secrets you typed; review it before sharing.',
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: controller.busy ? null : controller.prepareExport,
            child: const Text('Load saved records for export'),
          ),
          if (controller.exportPreview case final archive?) ...[
            summary(archive),
            FilledButton(
              onPressed: controller.busy || !controller.files.canExport
                  ? null
                  : controller.exportFile,
              child: const Text('Choose export file'),
            ),
          ],
          if (!controller.files.canExport)
            const Text(
              'File export is available in the desktop app. Import remains available here.',
            ),
          const Divider(height: 32),
          const Text(
            'Import can save a separate data copy or explicitly restore these records into a new Flutter web workspace. Existing projects are never replaced. A restored workspace starts with a fresh prototype and no source files, build history or Plan approval. Open it from Projects after restoring; no code runs here.',
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: controller.busy ? null : controller.pickImport,
            child: const Text('Select archive file (up to 1 MiB)'),
          ),
          if (controller.importPreview case final archive?) ...[
            summary(archive),
            TextField(
              controller: backupId,
              enabled: !controller.busy,
              maxLength: 80,
              decoration: const InputDecoration(
                labelText: 'New backup or project ID',
                helperText: 'Letters, digits, underscores and hyphens; existing IDs refuse replacement.',
              ),
            ),
            FilledButton(
              onPressed: controller.busy
                  ? null
                  : () => controller.saveCopy(backupId.text),
              child: const Text('Save separate data copy'),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: projectName,
              enabled: !controller.busy,
              maxLength: 200,
              decoration: const InputDecoration(labelText: 'New project name'),
            ),
            OutlinedButton(
              onPressed: controller.busy
                  ? null
                  : () => controller.restoreWorkspace(
                      backupId.text,
                      projectName.text,
                    ),
              child: const Text('Restore records into new project'),
            ),
          ],
          if (controller.busy) const LinearProgressIndicator(),
          if (controller.status case final status?) SelectableText(status),
          if (controller.error case final error?)
            SelectableText(
              error,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
  );
}
