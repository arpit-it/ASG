import 'package:flutter/material.dart';

import 'workspace_panes.dart';

import '../controllers/portable_archive_controller.dart';
import 'portable_archive_screen.dart';

import '../controllers/requirements_controller.dart';
import '../services/requirements_store.dart';
import 'requirements_screen.dart';
import '../models/project.dart';
import '../models/generation_event.dart';
import '../controllers/app_workspace_controller.dart';
import 'live_application_view.dart';
import 'model_chat.dart';
import '../services/conversation_store.dart';
import 'generation_status_view.dart';
import 'source_generation_screen.dart';
import '../controllers/source_generation_controller.dart';
import '../services/source_generation_store.dart';
import '../services/generation_host_factory.dart';
import '../services/record_storage.dart';
import '../services/application_store.dart';

class ProjectWorkspace extends StatefulWidget {
  const ProjectWorkspace({
    super.key,
    required this.project,
    this.embedded = false,
    this.controller,
    this.records,
    this.onPendingChanged,
  });
  final StudioProject project;
  final RecordStorage? records;
  final ValueChanged<bool>? onPendingChanged;
  final bool embedded;
  final AppWorkspaceController? controller;
  @override
  State<ProjectWorkspace> createState() => _ProjectWorkspaceState();
}

class _ProjectWorkspaceState extends State<ProjectWorkspace> {
  late final controller =
      widget.controller ??
      AppWorkspaceController(
        widget.project,
        openStore: widget.records == null
            ? null
            : () async => ApplicationStore(widget.records!),
      );
  final input = TextEditingController();
  final conversationScroll = ScrollController();
  int lastMessageCount = 0;
  String lastDraft = '';
  bool lastBusy = false;
  @override
  void initState() {
    super.initState();
    controller.addListener(refresh);
    controller.load();
  }

  void refresh() {
    if (!mounted) return;
    setState(() {});
    widget.onPendingChanged?.call(
      controller.busy ||
          controller.savingInteractions ||
          controller.hasUnsavedInteractions,
    );
    if (controller.messages.length != lastMessageCount ||
        controller.draftResponse != lastDraft ||
        controller.busy != lastBusy) {
      lastMessageCount = controller.messages.length;
      lastDraft = controller.draftResponse;
      lastBusy = controller.busy;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && conversationScroll.hasClients) {
          conversationScroll.jumpTo(
            conversationScroll.position.maxScrollExtent,
          );
        }
      });
    }
  }

  @override
  void dispose() {
    controller.removeListener(refresh);
    controller.dispose();
    conversationScroll.dispose();
    input.dispose();
    super.dispose();
  }

  Future<void> send() async {
    if (await controller.apply(input.text) && mounted) input.clear();
  }

  Future<void> portableRecords() async {
    final records = controller.records;
    if (records is! ConditionalRecordStorage ||
        controller.busy ||
        controller.savingInteractions ||
        controller.hasUnsavedInteractions) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PortableArchiveScreen(
          controller: PortableArchiveController(widget.project.id, records),
        ),
      ),
    );
  }

  Future<void> requirements() async {
    final records = controller.records;
    if (records == null ||
        controller.busy ||
        controller.savingInteractions ||
        controller.hasUnsavedInteractions) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RequirementsScreen(
          controller: RequirementsController(
            widget.project.id,
            RequirementsStore(records),
          ),
          projectName: widget.project.name,
        ),
      ),
    );
  }

  Future<void> discussAndPlan() async {
    final records = controller.records;
    if (records == null ||
        controller.busy ||
        controller.savingInteractions ||
        controller.hasUnsavedInteractions) {
      return;
    }
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ModelChat(
          project: widget.project,
          openStore: () async => ConversationStore(records),
        ),
      ),
    );
  }

  Future<void> generateSource() async {
    if (controller.busy ||
        controller.savingInteractions ||
        controller.hasUnsavedInteractions) {
      return;
    }
    final records = controller.records;
    final definition = controller.definition;
    if (records == null || definition == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => SourceGenerationScreen(
          controller: SourceGenerationController(
            project: widget.project,
            definition: definition,
            store: SourceGenerationStore(records),
            host: createGenerationHost(),
          ),
        ),
      ),
    );
  }

  String get phaseLabel => switch (controller.phase) {
    GenerationPhase.thinking => 'Thinking…',
    GenerationPhase.writing => 'Writing response…',
    GenerationPhase.validating => 'Checking the update…',
    GenerationPhase.applying => 'Applying changes…',
    GenerationPhase.cancelling => 'Stopping…',
    GenerationPhase.idle => 'Ready',
  };

  Widget chat() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Expanded(
              child: Text(
                'Chat',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: 'Portable records',
              onPressed:
                  controller.records is! ConditionalRecordStorage ||
                      controller.busy ||
                      controller.savingInteractions ||
                      controller.hasUnsavedInteractions
                  ? null
                  : portableRecords,
              icon: const Icon(Icons.import_export),
            ),
            IconButton(
              tooltip: 'Requirements and tasks',
              onPressed:
                  controller.records == null ||
                      controller.busy ||
                      controller.savingInteractions ||
                      controller.hasUnsavedInteractions
                  ? null
                  : requirements,
              icon: const Icon(Icons.checklist),
            ),
            IconButton(
              tooltip: 'Discuss, plan and review',
              onPressed:
                  controller.records == null ||
                      controller.busy ||
                      controller.savingInteractions ||
                      controller.hasUnsavedInteractions
                  ? null
                  : discussAndPlan,
              icon: const Icon(Icons.forum_outlined),
            ),
          ],
        ),
      ),
      Expanded(
        child: ListView(
          controller: conversationScroll,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          children: [
            const Card(
              child: Padding(
                padding: EdgeInsets.all(16),
                child: Text(
                  'Your live application is ready. Tell me what you want to change. I’ll apply supported updates and refresh the preview.',
                ),
              ),
            ),
            ...controller.messages.map(
              (m) => Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.role == 'user' ? 'You' : 'Studio',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      SelectableText(m.content),
                    ],
                  ),
                ),
              ),
            ),
            if (controller.pendingInstruction != null)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'You',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 8),
                      Text(controller.pendingInstruction!),
                    ],
                  ),
                ),
              ),
            if (controller.busy)
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              phaseLabel,
                              key: const ValueKey('generationPhase'),
                              style: const TextStyle(
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (controller.draftResponse.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        SelectableText(
                          controller.draftResponse,
                          key: const ValueKey('streamingResponse'),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            if (controller.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: SelectableText(
                  controller.error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
          ],
        ),
      ),
      if (controller.busy)
        GenerationStatusView(
          phase: controller.phase,
          onStop: controller.cancelGeneration,
        ),

      Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            TextField(
              controller: input,
              enabled: !controller.busy && controller.definition != null,
              minLines: 2,
              maxLines: 5,
              maxLength: 2000,
              decoration: const InputDecoration(
                hintText:
                    'For example: add a counter and change the theme to green',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton.icon(
                onPressed: controller.busy || controller.definition == null
                    ? null
                    : send,
                icon: const Icon(Icons.auto_awesome),
                label: const Text('Apply instruction'),
              ),
            ),
          ],
        ),
      ),
    ],
  );
  Widget preview() => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Padding(
        padding: const EdgeInsets.all(16),
        child: Wrap(
          spacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            const Icon(Icons.play_circle_outline, size: 20),
            const SizedBox(width: 8),
            const Text('Application preview', style: TextStyle(fontSize: 18)),
            IconButton(
              tooltip: 'Generate Flutter source',
              onPressed:
                  controller.busy ||
                      controller.savingInteractions ||
                      controller.hasUnsavedInteractions ||
                      controller.definition == null
                  ? null
                  : generateSource,
              icon: const Icon(Icons.code),
            ),
            Text(
              controller.definition == null
                  ? 'Loading'
                  : controller.savingInteractions
                  ? 'Saving…'
                  : controller.hasUnsavedInteractions
                  ? 'Unsaved changes'
                  : 'Live · v${controller.revision}',
            ),
          ],
        ),
      ),
      if (controller.hasUnsavedInteractions && !controller.savingInteractions)
        TextButton(
          onPressed: controller.busy ? null : controller.saveInteractions,
          child: const Text('Retry saving preview'),
        ),
      const Padding(
        padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
        child: Text(
          'Interactive in-app prototype · no external build',
          style: TextStyle(color: Colors.white60, fontSize: 12),
        ),
      ),
      Expanded(
        child: controller.definition == null
            ? Center(
                child: Text(
                  controller.error == null
                      ? 'Restoring your application…'
                      : 'Application unavailable',
                ),
              )
            : ClipRRect(
                borderRadius: const BorderRadius.all(Radius.circular(12)),
                child: IgnorePointer(
                  ignoring: controller.busy,
                  child: LiveApplicationView(
                    key: ValueKey(widget.project.id),
                    definition: controller.definition!,
                    enabled: !controller.busy,
                    onStateChanged: controller.recordRuntimeState,
                  ),
                ),
              ),
      ),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final body = WorkspacePanes(
      chat: chat(),
      preview: Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 16, 16),
        child: preview(),
      ),
    );
    return PopScope(
      canPop:
          !controller.busy &&
          !controller.savingInteractions &&
          !controller.hasUnsavedInteractions,
      child: widget.embedded
          ? body
          : Scaffold(
              appBar: AppBar(title: Text(widget.project.name)),
              body: body,
            ),
    );
  }
}
