// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/imported_plan_controller.dart';

class ImportedPlanScreen extends StatefulWidget {
  const ImportedPlanScreen({
    super.key,
    required this.controller,
    this.onCommittedProposal,
  });
  final ImportedPlanController controller;
  final VoidCallback? onCommittedProposal;
  @override
  State<ImportedPlanScreen> createState() => _ImportedPlanScreenState();
}

class _ImportedPlanScreenState extends State<ImportedPlanScreen> {
  final text = TextEditingController();
  ImportedPlanController get controller => widget.controller;
  bool hydrated = false;
  bool edited = false;
  Future<void> load() async {
    final owner = controller;
    await owner.load();
    if (mounted &&
        identical(owner, controller) &&
        owner.error == null &&
        !hydrated &&
        !edited) {
      hydrated = true;
      text.text = owner.plan?.text ?? '';
    }
  }

  @override
  void initState() {
    super.initState();
    load();
  }

  @override
  void didUpdateWidget(covariant ImportedPlanScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.controller, controller)) {
      oldWidget.controller.dispose();
      hydrated = false;
      edited = false;
      text.clear();
      load();
    }
  }

  @override
  void dispose() {
    text.dispose();
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => PopScope(
      canPop: !controller.busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Imported project plan')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Write a plan against saved requirements and the workspace’s captured metadata. Reload refreshes saved planning data only. Reinspect the folder explicitly to refresh disk metadata. Approval records review consent only; source editing and execution are unavailable and no project files are changed.',
            ),
            SelectableText('Folder: ${controller.root}'),
            if (controller.capturedCommit != null) ...[
              const Text(
                'This plan uses selected immutable commit source. Saving stores that source and provenance locally in ASG application records. Approval is review consent only. Current working files and conflicts remain unknown; workspace package, SDK and runners are not verified for this commit.',
              ),
              SelectableText('Commit: ${controller.capturedCommit!.commit}'),
              SelectableText('Commit tree: ${controller.capturedCommit!.tree}'),
              SelectableText(
                'Manifest SHA-256: ${controller.capturedCommit!.manifestDigest} (${controller.capturedCommit!.manifestFiles} files)',
              ),
            ],
            if (controller.capturedContext != null) ...[
              Text(
                controller.capturedContext!.includesSource
                    ? 'This draft uses historical captured source. Saving stores its text and provenance locally in ASG application records. No model sharing, repository writes or execution is authorized. Changed requirements invalidate this capture; return to review and prepare a new context.'
                    : 'This draft uses historical captured documents. Saving stores their text and provenance locally in ASG application records. No model sharing, repository writes or execution is authorized. Changed requirements invalidate this capture; return to review and prepare a new context.',
              ),
              SelectableText(
                'Captured context SHA-256: ${controller.capturedContext!.digest}',
              ),
              ExpansionTile(
                title: Text(
                  controller.capturedContext!.includesSource
                      ? 'Review captured source text'
                      : 'Review captured document text',
                ),
                children: [
                  for (final document
                      in controller.capturedContext!.capturedFiles)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SelectableText(
                            '${document.path} · ${document.byteLength} bytes',
                          ),
                          SelectableText('SHA-256: ${document.digest}'),
                          SelectableText(
                            document.text.isEmpty
                                ? (controller.capturedContext!.includesSource
                                      ? '[Empty source file]'
                                      : '[Empty document]')
                                : document.text,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ],
            if (controller.busy) const LinearProgressIndicator(),
            if (controller.error != null) ...[
              SelectableText(controller.error!),
              TextButton(
                onPressed: controller.busy ? null : load,
                child: const Text('Reload plan'),
              ),
            ],
            TextField(
              controller: text,
              onChanged: (_) => edited = true,
              enabled: !controller.busy,
              maxLength: 12000,
              minLines: 5,
              maxLines: 12,
              decoration: const InputDecoration(
                labelText: 'Plan draft (user authored)',
              ),
            ),
            FilledButton(
              onPressed: controller.busy
                  ? null
                  : () => controller.saveDraft(text.text),
              child: const Text('Save draft'),
            ),
            if (widget.onCommittedProposal != null)
              OutlinedButton(
                onPressed: controller.canReviewCommittedProposal
                    ? widget.onCommittedProposal
                    : null,
                child: const Text('Review committed-source change'),
              ),
            if (controller.plan != null) ...[
              Text(
                controller.approved
                    ? 'Approved for captured planning context'
                    : controller.current
                    ? 'Saved draft · not approved'
                    : 'Outdated or unavailable context · approval inactive',
              ),
              SelectableText('Saved plan: ${controller.plan!.text}'),
              Text('Recorded: ${controller.plan!.recordedAt.toLocal()}'),
              Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed:
                        controller.busy ||
                            !controller.current ||
                            controller.approved
                        ? null
                        : () => controller.decide(true),
                    child: const Text('Approve saved plan'),
                  ),
                  TextButton(
                    onPressed:
                        controller.busy ||
                            !controller.current ||
                            !controller.plan!.approved
                        ? null
                        : () => controller.decide(false),
                    child: const Text('Withdraw approval'),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    ),
  );
}
