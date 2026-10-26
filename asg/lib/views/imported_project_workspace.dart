import 'package:flutter/material.dart';

import '../controllers/requirements_controller.dart';
import '../models/project_inspection.dart';
import '../services/inspected_folder_store.dart';
import '../services/record_storage.dart';
import '../services/requirements_store.dart';
import 'requirements_screen.dart';

/// Planning records for an inspected folder, without a generated prototype.
class ImportedProjectWorkspace extends StatelessWidget {
  const ImportedProjectWorkspace({
    super.key,
    required this.inspection,
    required this.records,
  });

  final ProjectInspection inspection;
  final RecordStorage records;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Imported project workspace')),
    body: ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          inspection.packageName,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        SelectableText('Folder: ${inspection.root}'),
        SelectableText('Declared Dart SDK: ${inspection.dartSdk}'),
        Text(
          'Included runners: ${inspection.runners.isEmpty ? 'None found' : inspection.runners.join(', ')}',
        ),
        const SizedBox(height: 16),
        const Text(
          'Requirements and tasks are saved in ASG application storage for this '
          'folder location. They do not change files in the imported project. '
          'Moving or renaming the folder starts a separate workspace.',
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => RequirementsScreen(
                controller: RequirementsController(
                  InspectedFolderStore.workspaceId(inspection.root),
                  RequirementsStore(records),
                ),
                projectName: inspection.packageName,
              ),
            ),
          ),
          icon: const Icon(Icons.checklist),
          label: const Text('Requirements and tasks'),
        ),
        const SizedBox(height: 16),
        for (final limitation in ProjectInspection.limitations)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(limitation),
          ),
        const Text(
          'Imported-project plan approval, source editing, execution and preview '
          'are not available yet. Opening this workspace grants no write or '
          'execution approval.',
        ),
      ],
    ),
  );
}
