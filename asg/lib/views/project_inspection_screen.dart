// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/project_inspection_controller.dart';
import '../models/project_inspection.dart';
import '../models/project_metadata_observation.dart';
import 'imported_project_workspace.dart';

/// Owns the controller and its pending selection lifecycle.
class ProjectInspectionScreen extends StatefulWidget {
  const ProjectInspectionScreen({super.key, required this.controller});
  final ProjectInspectionController controller;

  @override
  State<ProjectInspectionScreen> createState() =>
      _ProjectInspectionScreenState();
}

class _ProjectInspectionScreenState extends State<ProjectInspectionScreen> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void didUpdateWidget(covariant ProjectInspectionScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller.removeListener(refresh);
      oldWidget.controller.dispose();
      widget.controller.addListener(refresh);
    }
  }

  Future<bool> confirm(
    ProjectInspectionController current,
    ProjectMetadataReadRequest request,
  ) async {
    if (!mounted ||
        !identical(current, widget.controller) ||
        current.isDisposed) {
      return false;
    }
    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        scrollable: true,
        title: const Text('Inspect current project metadata?'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Run the packaged read-only helper using this existing interpreter. '
                'Only bounded manifest data and entry metadata are read. No Git or project commands, '
                'model loading, installation or project-file writes are performed.',
              ),
              const SizedBox(height: 12),
              SelectableText('Folder: ${request.root}'),
              SelectableText('Existing interpreter: ${request.python}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Inspect metadata'),
          ),
        ],
      ),
    );
    return result == true &&
        mounted &&
        identical(current, widget.controller) &&
        !current.isDisposed;
  }

  Future<void> chooseFolder() async {
    final current = widget.controller;
    await current.chooseFolder(confirm: (request) => confirm(current, request));
  }

  Future<void> reopen(String root) async {
    final current = widget.controller;
    await current.reopen(root, confirm: (request) => confirm(current, request));
  }

  Future<void> openWorkspace() async {
    final current = widget.controller;
    final findings = await current.openWorkspace(
      confirm: (request) => confirm(current, request),
    );
    if (!mounted ||
        !identical(current, widget.controller) ||
        current.isDisposed ||
        current.stale ||
        findings == null ||
        !identical(current.findings, findings)) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ImportedProjectWorkspace(
          inspection: findings,
          records: current.store!.records,
        ),
      ),
    );
  }

  @override
  void dispose() {
    widget.controller.removeListener(refresh);
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final findings = controller.findings;
    return Scaffold(
      appBar: AppBar(title: const Text('Inspect existing Flutter project')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 800),
          child: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Select an existing Flutter folder to inspect its declared metadata. '
                'A confirmed packaged helper reads bounded metadata without changing project files or running Git/project commands.',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed:
                    controller.busy ||
                        !controller.supported ||
                        controller.cleanupUncertain
                    ? null
                    : chooseFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose Flutter folder'),
              ),
              if (!controller.supported)
                const Text(
                  'Contained folder inspection is available only on the verified Mac host. Other hosts remain unverified.',
                ),
              const Text(
                'Uses an existing absolute Python interpreter from Runtime setup. '
                'Settings are not changed and packages are not installed by inspection.',
              ),
              if (controller.storageError != null)
                Text(controller.storageError!),
              if (controller.savedFolders.isNotEmpty) ...[
                const SizedBox(height: 16),
                Text(
                  'Saved folders',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const Text(
                  'Reopening reads current files. Saved references grant no write or execution approval.',
                ),
                for (final root in controller.savedFolders)
                  ListTile(
                    title: Text(root),
                    trailing: const Icon(Icons.refresh),
                    onTap:
                        controller.busy ||
                            !controller.supported ||
                            controller.cleanupUncertain
                        ? null
                        : () => reopen(root),
                  ),
              ],
              if (controller.busy) ...[
                const SizedBox(height: 16),
                if (!controller.confirming) const LinearProgressIndicator(),
                Text(
                  controller.saving
                      ? 'Saving folder reference…'
                      : controller.confirming
                      ? 'Awaiting confirmation…'
                      : controller.stopping
                      ? 'Finishing inspection…'
                      : 'Selecting or inspecting folder…',
                ),
                if (controller.canStop || controller.stopping)
                  OutlinedButton(
                    onPressed: controller.canStop ? controller.cancel : null,
                    child: Text(
                      controller.stopping
                          ? 'Finishing inspection…'
                          : 'Stop inspection',
                    ),
                  ),
              ],
              if (controller.error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(
                    controller.error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
              if (findings != null) ...[
                if (controller.stale)
                  const Text(
                    'Previous findings retained — not a current inspection.',
                  ),
                const SizedBox(height: 24),
                Text(
                  'Inspection findings',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                SelectableText('Folder: ${findings.root}'),
                SelectableText('Package: ${findings.packageName}'),
                SelectableText('Declared Dart SDK: ${findings.dartSdk}'),
                Text(
                  'Included runners: ${findings.runners.isEmpty ? 'None found' : findings.runners.join(', ')}',
                ),
                const SizedBox(height: 16),
                for (final limitation in ProjectInspection.limitations)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(limitation),
                  ),
                FilledButton.icon(
                  onPressed: controller.canSave ? controller.saveFolder : null,
                  icon: const Icon(Icons.bookmark_add_outlined),
                  label: const Text('Save folder reference'),
                ),
                OutlinedButton.icon(
                  onPressed: controller.canOpenWorkspace ? openWorkspace : null,
                  icon: const Icon(Icons.workspaces_outline),
                  label: const Text('Open requirements workspace'),
                ),
                const Text(
                  'These findings describe this inspection only. Saving remembers '
                  'the folder for fresh inspection. Open its requirements workspace '
                  'after saving. Imported source editing, execution and preview remain unavailable; '
                  'inspection grants no write or execution approval.',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
