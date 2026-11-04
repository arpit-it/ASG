// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/html_project_controller.dart';
import '../controllers/html_plan_check_controller.dart';
import '../services/html/html_starter_runner.dart';
import '../controllers/requirements_controller.dart';
import '../services/requirements_store.dart';
import 'requirements_screen.dart';
import 'model_chat.dart';
import '../services/conversation_store.dart';
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
  late final planCheck = HtmlPlanCheckController(
    widget.project,
    widget.records,
    HtmlStarterRunner(),
  );
  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
    planCheck.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    planCheck.removeListener(refresh);
    planCheck.dispose();
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

  Future<void> chat() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => ModelChat(
          project: widget.project,
          openStore: () async => ConversationStore(widget.records),
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
          'Registration remembers the original export. Opening this workspace does not read source files, run checks, start a preview or approve Build tasks. Open the starter to request exact-source checks and local preview. An approved Plan can authorize its first source identity check below. Preview dispatch from Plans and arbitrary edited-source execution remain planned.',
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
        const SizedBox(height: 12),
        const Text(
          'After approving a current fixed HTML Plan in chat, explicitly run its first source identity check. This does not run the preview, complete the Plan or update task status.',
        ),
        OutlinedButton(
          onPressed: planCheck.busy || !planCheck.supported
              ? null
              : planCheck.check,
          child: const Text('Check approved HTML sources'),
        ),
        if (!planCheck.supported)
          const Text(
            'Approved HTML source checks require the macOS fixed-starter host.',
          ),
        if (planCheck.busy) ...[
          const LinearProgressIndicator(),
          OutlinedButton(
            onPressed: planCheck.stop,
            child: const Text('Stop source check'),
          ),
        ],
        if (planCheck.message != null) Text(planCheck.message!),
        if (planCheck.result != null) Text(planCheck.result!.summary),
        OutlinedButton(
          onPressed: controller.starter == null ? null : chat,
          child: const Text('Discuss and plan HTML'),
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
