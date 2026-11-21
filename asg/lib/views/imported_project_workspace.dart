// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/requirements_controller.dart';
import '../models/project_inspection.dart';
import 'imported_commit_proposal_screen.dart';
import 'imported_commit_copy_screen.dart';
import 'imported_commit_edit_screen.dart';
import 'imported_commit_edit_comparison_screen.dart';
import 'imported_dart_diagnostics_screen.dart';
import '../controllers/imported_dart_diagnostics_controller.dart';
import '../services/imported_dart_diagnostics_store.dart';
import '../services/imported_dart_diagnostics_host_factory.dart';
import '../controllers/imported_commit_edit_comparison_controller.dart';
import '../services/imported_commit_edit_comparison_store.dart';
import '../services/imported_commit_edit_comparison_host_factory.dart';
import '../controllers/imported_commit_edit_controller.dart';
import '../services/imported_commit_edit_store.dart';
import '../services/imported_commit_edit_host_factory.dart';
import '../controllers/imported_commit_copy_recheck_controller.dart';
import '../services/imported_commit_copy_recheck_store.dart';
import '../services/imported_commit_copy_recheck_host_factory.dart';
import 'imported_commit_copy_recheck_screen.dart';

import '../controllers/imported_commit_copy_controller.dart';
import '../services/imported_commit_copy_store.dart';
import '../services/imported_commit_copy_host_factory.dart';
import '../controllers/imported_commit_proposal_controller.dart';
import '../services/imported_commit_proposal_store.dart';
import '../services/inspected_folder_store.dart';
import '../services/record_storage.dart';
import '../services/requirements_store.dart';
import 'requirements_screen.dart';
import 'imported_source_baseline_screen.dart';
import 'imported_commit_comparison_screen.dart';
import '../controllers/imported_commit_comparison_controller.dart';
import '../services/imported_commit_comparison_store.dart';
import '../controllers/imported_source_baseline_controller.dart';
import '../services/imported_source_baseline_store.dart';
import 'git_metadata_panel.dart';
import 'imported_index_panel.dart';
import 'project_instruction_panel.dart';
import 'project_source_panel.dart';
import 'imported_source_proposal_screen.dart';
import '../controllers/imported_source_proposal_controller.dart';
import '../services/imported_source_proposal_store.dart';
import 'imported_plan_screen.dart';
import 'imported_advisory_screen.dart';
import '../controllers/imported_advisory_controller.dart';
import '../services/imported_advisory_store.dart';
import '../controllers/imported_plan_controller.dart';
import '../services/imported_plan_store.dart';

/// Planning records for an inspected folder, without a generated prototype.
class ImportedProjectWorkspace extends StatelessWidget {
  const ImportedProjectWorkspace({
    super.key,
    required this.inspection,
    required this.records,
  });

  final ProjectInspection inspection;
  final RecordStorage records;

  Widget _editScreen(
    BuildContext context, {
    required ImportedCommitEditController controller,
  }) => ImportedCommitEditScreen(
    controller: controller,
    onCompare: (history) {
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImportedCommitEditComparisonScreen(
            onDiagnostics: (comparison, observation) {
              if (!context.mounted) return;
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ImportedDartDiagnosticsScreen(
                    controller: ImportedDartDiagnosticsController(
                      comparison: comparison,
                      observation: observation,
                      store: ImportedDartDiagnosticsStore(records),
                      host: createImportedDartDiagnosticsHost(),
                    ),
                  ),
                ),
              );
            },
            controller: ImportedCommitEditComparisonController(
              root: inspection.root,
              expectedEditHistoryDigest: history.digest,
              store: ImportedCommitEditComparisonStore(records),
              host: createImportedCommitEditComparisonHost(),
            ),
          ),
        ),
      );
    },
  );

  Widget _copyScreen(
    BuildContext context, {
    required ImportedCommitCopyController controller,
  }) => ImportedCommitCopyScreen(
    controller: controller,
    onPropose: (history) {
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _editScreen(
            context,
            controller: ImportedCommitEditController(
              root: inspection.root,
              inspection: inspection,
              expectedCopyDigest: history.digest,
              store: ImportedCommitEditStore(records),
              host: createImportedCommitEditHost(),
              reader: createImportedCommitCopyRecheckHost(),
            ),
          ),
        ),
      );
    },
    onRecheck: (history) {
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImportedCommitCopyRecheckScreen(
            controller: ImportedCommitCopyRecheckController(
              root: inspection.root,
              expectedHistoryDigest: history.digest,
              store: ImportedCommitCopyRecheckStore(records),
              host: createImportedCommitCopyRecheckHost(),
            ),
          ),
        ),
      );
    },
  );

  Widget _committedProposal(
    BuildContext context,
    ImportedCommitProposalController controller,
  ) => ImportedCommitProposalScreen(
    controller: controller,
    onPrepareCopy: (saved) {
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => _copyScreen(
            context,
            controller: ImportedCommitCopyController(
              root: inspection.root,
              inspection: inspection,
              expectedHistoryDigest: saved.digest,
              store: ImportedCommitCopyStore(records),
              host: createImportedCommitCopyHost(),
            ),
          ),
        ),
      );
    },
  );

  Widget _comparisonScreen(
    BuildContext context,
    ImportedSourceProposalController controller,
  ) => ImportedSourceProposalScreen(
    controller: controller,
    onCommitComparison: (saved) {
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImportedCommitComparisonScreen(
            controller: ImportedCommitComparisonController(
              saved: saved,
              store: ImportedCommitComparisonStore(records),
            ),
            inspection: inspection,
            onPlan: (captured) {
              if (!context.mounted) return;
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ImportedPlanScreen(
                    controller: ImportedPlanController(
                      inspection.root,
                      ImportedPlanStore(records, capturedCommit: captured),
                      inspection: inspection,
                    ),
                    onCommittedProposal: () {
                      if (!context.mounted) return;
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => _committedProposal(
                            context,
                            ImportedCommitProposalController(
                              inspection: inspection,
                              context: captured,
                              store: ImportedCommitProposalStore(records),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              );
            },
          ),
        ),
      );
    },
    onBaseline: (saved) {
      if (!context.mounted) return;
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => ImportedSourceBaselineScreen(
            controller: ImportedSourceBaselineController(
              saved: saved,
              store: ImportedSourceBaselineStore(records),
            ),
          ),
        ),
      );
    },
  );

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
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ImportedPlanScreen(
                controller: ImportedPlanController(
                  inspection.root,
                  ImportedPlanStore(records),
                  inspection: inspection,
                ),
              ),
            ),
          ),
          icon: const Icon(Icons.approval),
          label: const Text('Plan and approval'),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _comparisonScreen(
                context,
                ImportedSourceProposalController.history(
                  root: inspection.root,
                  store: ImportedSourceProposalStore(records),
                ),
              ),
            ),
          ),
          icon: const Icon(Icons.history),
          label: const Text('Open saved source comparison'),
        ),
        const SizedBox(height: 16),
        for (final limitation in ProjectInspection.limitations)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(limitation),
          ),
        const Text(
          'Imported-project source editing, execution and preview '
          'are not available yet. Opening this workspace grants no write or '
          'execution approval.',
        ),
        const SizedBox(height: 16),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _committedProposal(
                context,
                ImportedCommitProposalController.history(
                  root: inspection.root,
                  store: ImportedCommitProposalStore(records),
                ),
              ),
            ),
          ),
          icon: const Icon(Icons.history),
          label: const Text('Open saved committed-source comparison'),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _copyScreen(
                context,
                controller: ImportedCommitCopyController(
                  root: inspection.root,
                  store: ImportedCommitCopyStore(records),
                  host: createImportedCommitCopyHost(),
                ),
              ),
            ),
          ),
          icon: const Icon(Icons.history),
          label: const Text('Open baseline-copy history'),
        ),
        OutlinedButton.icon(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _editScreen(
                context,
                controller: ImportedCommitEditController(
                  root: inspection.root,
                  store: ImportedCommitEditStore(records),
                  host: createImportedCommitEditHost(),
                  reader: createImportedCommitCopyRecheckHost(),
                ),
              ),
            ),
          ),
          icon: const Icon(Icons.history),
          label: const Text('Open proposed-copy history'),
        ),
        ProjectSourcePanel(
          root: inspection.root,
          records: records,
          inspection: inspection,
          onProposal: (captured) {
            if (!context.mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => _comparisonScreen(
                  context,
                  ImportedSourceProposalController(
                    inspection: inspection,
                    context: captured,
                    store: ImportedSourceProposalStore(records),
                  ),
                ),
              ),
            );
          },
          onPlan: (captured) {
            if (!context.mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ImportedPlanScreen(
                  controller: ImportedPlanController(
                    inspection.root,
                    ImportedPlanStore(records, capturedSource: captured),
                    inspection: inspection,
                  ),
                ),
              ),
            );
          },
          onAdvisory: (captured) {
            if (!context.mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ImportedAdvisoryScreen(
                  controller: ImportedAdvisoryController(
                    inspection: inspection,
                    context: captured,
                    store: ImportedAdvisoryStore(records),
                  ),
                ),
              ),
            );
          },
        ),
        ProjectInstructionPanel(
          key: ValueKey('instructions-${inspection.root}'),
          root: inspection.root,
          records: records,
          inspection: inspection,
          onAdvisory: (captured) {
            if (!context.mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ImportedAdvisoryScreen(
                  controller: ImportedAdvisoryController(
                    inspection: inspection,
                    context: captured,
                    store: ImportedAdvisoryStore(records),
                  ),
                ),
              ),
            );
          },
          onPlan: (captured) {
            if (!context.mounted) return;
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => ImportedPlanScreen(
                  controller: ImportedPlanController(
                    inspection.root,
                    ImportedPlanStore(records, capturedDocuments: captured),
                    inspection: inspection,
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        GitMetadataPanel(
          key: ValueKey(inspection.root),
          root: inspection.root,
          records: records,
        ),
        const SizedBox(height: 16),
        ImportedIndexPanel(root: inspection.root, records: records),
        const SizedBox(height: 16),
      ],
    ),
  );
}
