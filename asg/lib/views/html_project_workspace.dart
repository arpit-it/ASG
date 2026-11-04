// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/html_project_controller.dart';
import '../controllers/requirements_controller.dart';
import '../services/requirements_store.dart';
import 'requirements_screen.dart';
import '../controllers/html_export_controller.dart';
import '../models/project.dart';
import '../services/record_storage.dart';
import '../services/html/html_project_store.dart';
import '../services/html/html_starter_store.dart';
import '../services/html/html_source_export_factory.dart';
import 'html_export_screen.dart';

class HtmlProjectWorkspace extends StatefulWidget {
  const HtmlProjectWorkspace({
    super.key,
    required this.project,
    required this.records,
    this.embedded = false,
  });
  final StudioProject project;
  final RecordStorage records;
  final bool embedded;
  @override
  State<HtmlProjectWorkspace> createState() => _HtmlProjectWorkspaceState();
}

class _HtmlProjectWorkspaceState extends State<HtmlProjectWorkspace> {
  late final controller = HtmlProjectController(
    HtmlProjectStore(widget.records),
    widget.project,
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

  Future<void> requirements() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => RequirementsScreen(
          controller: RequirementsController(
            widget.project.id,
            RequirementsStore(widget.records),
          ),
          projectName: widget.project.name,
        ),
      ),
    );
  }

  Future<void> open() async {
    controller.reload();
    final starter = controller.starter;
    if (starter == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => HtmlExportScreen(
          controller: HtmlExportController(
            exporter: createHtmlSourceExport(),
            starterStore: HtmlStarterStore(widget.records),
            savedStarter: starter,
          ),
        ),
      ),
    );
    if (mounted) controller.reload();
  }

  @override
  Widget build(BuildContext context) {
    final body = ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          widget.project.name,
          style: Theme.of(context).textTheme.headlineSmall,
        ),
        const Text('Registered fixed HTML starter'),
        SelectableText(widget.project.location),
        const SizedBox(height: 12),
        const Text(
          'Registration remembers the original export. Opening this workspace does not read source files, run checks, start a preview or approve Build tasks. Open the starter to request exact-source checks and local preview. Arbitrary edited-source execution and approved-task integration remain planned.',
        ),
        const SizedBox(height: 12),
        const Text(
          'Record requirements and track tasks for this HTML project. Task status is manual progress, not approval to change source or verified HTML check evidence.',
        ),
        OutlinedButton(
          onPressed: requirements,
          child: const Text('Requirements and tasks'),
        ),
        if (controller.error != null) ...[
          Text(controller.error!),
          OutlinedButton(
            onPressed: controller.reload,
            child: const Text('Retry HTML metadata'),
          ),
        ],
        FilledButton(
          onPressed: controller.starter == null ? null : open,
          child: const Text('Open HTML starter'),
        ),
      ],
    );
    return widget.embedded
        ? body
        : Scaffold(
            appBar: AppBar(title: const Text('HTML project')),
            body: body,
          );
  }
}
