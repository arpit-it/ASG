// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import '../controllers/project_inspection_controller.dart';
import '../services/inspected_folder_store.dart';
import 'project_inspection_screen.dart';
import '../controllers/ask_controller.dart';
import '../services/ask_store.dart';
import 'ask_screen.dart';

import 'package:flutter/material.dart';

import '../controllers/studio_session_controller.dart';
import '../controllers/runtime_setup_controller.dart';
import '../models/project.dart';
import '../services/studio_store.dart';
import '../services/studio_session_store.dart';
import '../services/runtime_setup_store.dart';
import '../services/model_settings_store.dart';
import '../services/runtime_host_factory.dart';
import '../controllers/project_details_controller.dart';
import '../services/project_details_store.dart';
import 'project_details_dialog.dart';
import 'dashboard.dart';
import 'project_wizard.dart';
import 'project_workspace.dart';
import 'runtime_setup_screen.dart';
import 'app_licenses_button.dart';
import 'product_acceptance_screen.dart';

class StudioHome extends StatefulWidget {
  const StudioHome({super.key, required this.store, required this.projects});
  final StudioStore store;
  final List<StudioProject> projects;
  @override
  State<StudioHome> createState() => _StudioHomeState();
}

class _StudioHomeState extends State<StudioHome> {
  bool workspacePending = false;
  late final controller = StudioSessionController(
    StudioSessionStore(widget.store),
    widget.projects,
  );
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
    super.dispose();
  }

  void ask() => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) =>
          AskScreen(controller: AskController(AskStore(widget.store.records))),
    ),
  );

  Future<void> create() async {
    final project = await showDialog<StudioProject>(
      context: context,
      builder: (_) => const ProjectWizard(),
    );
    if (project != null) await controller.create(project);
  }

  Future<void> editDetails() async {
    final project = controller.current;
    if (project == null || controller.busy || workspacePending) return;
    final detailsController = ProjectDetailsController(
      project,
      ProjectDetailsStore(widget.store),
    );
    final saved = await showDialog<StudioProject>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ProjectDetailsDialog(controller: detailsController),
    );
    if (saved != null && mounted) controller.refreshCurrent();
  }

  Future<void> projects() async {
    final selected = await Navigator.of(context).push<StudioProject>(
      MaterialPageRoute(
        builder: (pageContext) => Dashboard(
          store: widget.store,
          initialProjects: widget.store.load(),
          onSelect: (project) => Navigator.pop(pageContext, project),
        ),
      ),
    );
    if (selected != null) await controller.select(selected);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(controller.current?.name ?? 'Automated Software Generator'),
      actions: [
        IconButton(
          tooltip: 'Ask engineering questions',
          onPressed: controller.busy || workspacePending ? null : ask,
          icon: const Icon(Icons.question_answer_outlined),
        ),
        IconButton(
          tooltip: 'Product acceptance evidence',
          onPressed: controller.busy || workspacePending
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ProductAcceptanceScreen(),
                  ),
                ),
          icon: const Icon(Icons.fact_check_outlined),
        ),
        AppLicensesButton(enabled: !controller.busy && !workspacePending),
        IconButton(
          tooltip: 'Inspect existing Flutter project',
          onPressed: controller.busy || workspacePending
              ? null
              : () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => ProjectInspectionScreen(
                      controller: ProjectInspectionController(
                        store: InspectedFolderStore(widget.store.records),
                      ),
                    ),
                  ),
                ),
          icon: const Icon(Icons.find_in_page_outlined),
        ),
        if (controller.current != null)
          IconButton(
            tooltip: 'Edit project details',
            onPressed: controller.busy || workspacePending ? null : editDetails,
            icon: const Icon(Icons.edit_note),
          ),
        IconButton(
          tooltip: 'Projects',
          onPressed: controller.busy || workspacePending ? null : projects,
          icon: const Icon(Icons.folder_open),
        ),
        IconButton(
          tooltip: 'New project',
          onPressed:
              controller.busy ||
                  workspacePending ||
                  controller.savedCreation != null
              ? null
              : create,
          icon: const Icon(Icons.add),
        ),
      ],
    ),
    floatingActionButtonLocation: const RuntimeFabLocation(),
    floatingActionButton: FloatingActionButton.small(
      tooltip: 'Set up runtime',
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => RuntimeSetupScreen(
            controller: RuntimeSetupController(
              store: RuntimeSetupStore(widget.store.records),
              modelStore: ModelSettingsStore(widget.store.records),
              host: createRuntimeHost(),
            ),
          ),
        ),
      ),
      child: const Icon(Icons.memory),
    ),
    body: AbsorbPointer(
      absorbing: controller.busy,
      child: ExcludeFocus(
        excluding: controller.busy,
        child: Column(
          children: [
            if (controller.error != null)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Text(
                  controller.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            if (controller.savedCreation != null)
              TextButton(
                onPressed: controller.busy || workspacePending
                    ? null
                    : controller.retrySavedCreation,
                child: const Text('Retry opening saved project'),
              ),
            if (controller.busy) const LinearProgressIndicator(),
            Expanded(
              child: controller.current != null
                  ? Padding(
                      padding: const EdgeInsets.only(top: 56),
                      child: ProjectWorkspace(
                        records: widget.store.records,
                        onPendingChanged: (value) {
                          if (mounted && workspacePending != value) {
                            setState(() => workspacePending = value);
                          }
                        },
                        key: ValueKey(controller.current!.id),
                        project: controller.current!,
                        embedded: true,
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, size) {
                        final welcome = Padding(
                          padding: const EdgeInsets.all(24),
                          child: ListView(
                            children: [
                              const Text(
                                'What would you like to create?',
                                style: TextStyle(
                                  fontSize: 28,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'Describe your idea. I’ll suggest options and guide the project setup, then your instructions can update its live prototype.',
                              ),
                              const SizedBox(height: 20),
                              OutlinedButton.icon(
                                onPressed: ask,
                                icon: const Icon(
                                  Icons.question_answer_outlined,
                                ),
                                label: const Text('Ask without a project'),
                              ),
                              const SizedBox(height: 12),
                              FilledButton.icon(
                                onPressed: controller.savedCreation != null
                                    ? null
                                    : create,
                                icon: const Icon(Icons.chat_bubble_outline),
                                label: const Text('Let’s create something'),
                              ),
                            ],
                          ),
                        );
                        const emptyPreview = Center(
                          child: Padding(
                            padding: EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(Icons.preview_outlined, size: 48),
                                SizedBox(height: 16),
                                Text(
                                  'Application preview',
                                  style: TextStyle(fontSize: 22),
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Create a project to start its live application. Your current project will reopen here next time.',
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                        );
                        if (size.maxWidth < 800) return welcome;
                        return Row(
                          children: [
                            SizedBox(
                              width: size.maxWidth * 0.4,
                              child: welcome,
                            ),
                            const VerticalDivider(width: 1),
                            const Expanded(child: emptyPreview),
                          ],
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    ),
  );
}
