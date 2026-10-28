// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../models/chat_message.dart';

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
  final savedCopyId = TextEditingController();
  final projectName = TextEditingController();
  final redactionText = TextEditingController();
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
    savedCopyId.dispose();
    projectName.dispose();
    redactionText.dispose();
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
      Text(
        archive.prototype == null
            ? 'No saved prototype included; restored prototype starts fresh.'
            : 'Saved prototype: ${archive.prototype!.definition.title} · revision ${archive.prototype!.revision}',
      ),
      Text('${archive.prototype?.messages.length ?? 0} prototype messages'),
      if (archive.project case final project?) ...[
        Text(
          'Saved project intent: ${project.type} · ${project.platforms.join(', ')}',
        ),
        SelectableText(project.description),
      ],
      if (archive.revisions.isNotEmpty) ...[
        const Text(
          'Historical revision summaries only; artifacts and rollback are unavailable.',
        ),
        for (final revision in archive.revisions)
          Text(
            '${revision.recordedAt?.toIso8601String() ?? 'Unknown time'} · ${revision.outcome} · ${revision.passedChecks}/${revision.totalChecks} recorded checks passed · historical inputs: ${revision.requirementsRevision == null ? 'unknown' : 'requirements ${revision.requirementsRevision}, prototype ${revision.prototypeRevision}'}',
          ),
      ],
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
          if (archive.prototype case final prototype?)
            ListTile(
              title: SelectableText(prototype.definition.title),
              subtitle: SelectableText(
                prototype.definition.elements
                    .map((e) => '${e.label}\n${e.items.join('\n')}\n${e.value}')
                    .join('\n'),
              ),
            ),
          for (final message
              in archive.prototype?.messages ?? const <ChatMessage>[])
            ListTile(
              title: Text('Prototype ${message.role}'),
              subtitle: SelectableText(message.content),
            ),
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

  Widget completeContents(String contents) => ExpansionTile(
    title: const Text('Review complete archive JSON'),
    subtitle: const Text(
      'Includes every exported field. Text may contain private information or secrets.',
    ),
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: SelectableText(contents),
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
            'Archives include saved requirements, tasks, board revision and Discuss/Plan/Review conversation text. Versions 2–6 also preserve the latest saved Plan decision; versions 3–6 include historical build outcome summaries and recording times. Versions 4–6 also retain known historical requirements/prototype input revision numbers. Versions 5–6 include the saved interpreted prototype definition and its revision. Earlier versions remain supported. These records cannot grant Build approval, verify artifacts or enable rollback. Version 6 also includes prototype conversation text. Execution contexts, build logs, source files, paths, settings and approval credentials are excluded. Text may contain private information or secrets you typed; review and redact the export copy before sharing.',
          ),
          const SizedBox(height: 16),
          const Text(
            'Export blocks recognized private-key headers, common token prefixes, '
            'Bearer credentials, password/key/token assignments, command-line credential values (including quoted/Markdown options) and URLs with '
            'passwords or HTTP(S) user-info (including token-only URLs). Detection '
            'also inspects one percent-encoded ASCII layer, is limited and can match '
            'examples. Other secrets and private text may still be included; '
            'review the complete archive before sharing. Nothing is automatically redacted. '
            'Literal redaction changes only the export copy; saved records stay unchanged. '
            'Identifiers and links cannot be redacted here. If redaction matches a planned test file or exact test name, its entire test mapping is removed from the export copy; reselect it after restore.',
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: controller.busy ? null : controller.prepareExport,
            child: const Text('Load saved records for export'),
          ),
          if (controller.exportReviewPreview case final archive?) ...[
            summary(archive),
            completeContents(controller.exportReviewContents!),
            TextField(
              controller: redactionText,
              enabled: !controller.busy,
              maxLength: PortableProjectArchive.maxMessageCharacters,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Literal text to redact from export copy',
                helperText: 'Paste exact text, not JSON escapes. All matches in authored text become [redacted].',
                helperMaxLines: 3,
              ),
            ),
            OutlinedButton(
              onPressed: controller.busy
                  ? null
                  : () async {
                      await controller.redactExport(redactionText.text);
                      if (mounted && controller.error == null) {
                        redactionText.clear();
                      }
                    },
              child: const Text('Redact export copy'),
            ),
            if (controller.exportPreview == null)
              const Text(
                'Export is blocked. Redact recognized credentials and review again.',
              ),
            FilledButton(
              onPressed:
                  controller.busy ||
                      controller.exportPreview == null ||
                      !controller.files.canExport
                  ? null
                  : controller.exportFile,
              child: Text(controller.files.exportButtonLabel),
            ),
          ],
          if (!controller.files.canExport)
            const Text(
              'File export is available in a desktop app or browser. Import remains available here.',
            ),
          const Divider(height: 32),
          const Text(
            'Import can save a separate data copy or explicitly restore these records into a new workspace. Saved software type and target platforms are intent, not verified build support. Existing projects are never replaced. A restored workspace uses the included saved prototype, or a fresh prototype for older archives, with no source files, executable build history or Plan approval. Open it from Projects after restoring; no code runs here.',
          ),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: controller.busy ? null : controller.pickImport,
            child: const Text('Select archive file (up to 1 MiB)'),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: savedCopyId,
            enabled: !controller.busy,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: 'Saved data copy ID',
              helperText: 'Reopen a copy previously saved in this app. Loading changes no records.',
            ),
          ),
          OutlinedButton(
            onPressed: controller.busy
                ? null
                : () => controller.loadCopy(savedCopyId.text),
            child: const Text('Load saved data copy'),
          ),
          OutlinedButton(
            onPressed: controller.busy
                ? null
                : () => controller.prepareCopyExport(savedCopyId.text),
            child: const Text('Load saved copy for export'),
          ),
          const Text(
            'To export a saved copy, load it for export, then review it above and choose an export file. No project is created.',
          ),
          if (controller.importPreview case final archive?) ...[
            summary(archive),
            completeContents(controller.importContents!),
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
