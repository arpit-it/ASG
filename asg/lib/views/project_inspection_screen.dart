import 'package:flutter/material.dart';

import '../controllers/project_inspection_controller.dart';
import '../models/project_inspection.dart';

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
                'Inspection reads files without changing them or running commands.',
              ),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: controller.busy || !controller.supported
                    ? null
                    : controller.chooseFolder,
                icon: const Icon(Icons.folder_open),
                label: const Text('Choose Flutter folder'),
              ),
              if (!controller.supported)
                const Text(
                  'Folder inspection is unavailable on this platform.',
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
                    onTap: controller.busy || !controller.supported
                        ? null
                        : () => controller.reopen(root),
                  ),
              ],
              if (controller.busy) ...[
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
                const Text('Selecting or inspecting folder…'),
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
                const Text(
                  'These findings describe this inspection only. Saving remembers '
                  'the folder for fresh inspection; it does not create a workspace '
                  'or approve a plan. Imported-project editing is not available yet.',
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
