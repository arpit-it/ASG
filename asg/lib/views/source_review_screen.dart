import 'package:flutter/material.dart';

import '../controllers/source_review_controller.dart';
import 'source_diff_view.dart';

class SourceReviewScreen extends StatefulWidget {
  const SourceReviewScreen({super.key, required this.controller});
  final SourceReviewController controller;
  @override
  State<SourceReviewScreen> createState() => _SourceReviewScreenState();
}

class _SourceReviewScreenState extends State<SourceReviewScreen>
    with WidgetsBindingObserver {
  String? taskId;
  final selected = <String>{};
  SourceReviewController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    controller.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) controller.refreshApproval();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.removeListener(refresh);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final evidence = controller.proposal;
    return Scaffold(
      appBar: AppBar(title: const Text('Review source proposal')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Request a local-model replacement for selected recorded Dart files. '
            'Prepare reviewed replacements in a separate folder with explicit consent. '
            'Candidates are unverified; the working source and preview remain unchanged. '
            'Candidate execution and promotion are not available yet.',
          ),
          SelectableText(controller.generated.directory),
          const SizedBox(height: 16),
          const Text('Approved board task'),
          for (final task in controller.tasks)
            CheckboxListTile(
              title: Text('${task.id}: ${task.title}'),
              value: taskId == task.id,
              onChanged: controller.busy
                  ? null
                  : (_) => setState(() => taskId = task.id),
            ),
          const Text('Recorded Dart files (select up to 8)'),
          for (final path in controller.paths)
            CheckboxListTile(
              title: Text(path),
              value: selected.contains(path),
              onChanged: controller.busy
                  ? null
                  : (value) => setState(() {
                      if (value == true) {
                        selected.add(path);
                      } else {
                        selected.remove(path);
                      }
                    }),
            ),
          FilledButton(
            onPressed:
                controller.busy ||
                    taskId == null ||
                    selected.isEmpty ||
                    selected.length > 8
                ? null
                : () => controller.request(taskId!, selected.toList()),
            child: const Text('Request source proposal'),
          ),
          if (controller.busy) ...[
            const LinearProgressIndicator(),
            TextButton(
              onPressed: controller.cancel,
              child: const Text('Cancel review'),
            ),
            const Text(
              'Cancellation closes the request; server-side inference may continue.',
            ),
          ],
          Text(controller.status),
          if (controller.error != null) SelectableText(controller.error!),
          if (controller.candidate != null) ...[
            const Text(
              'Retained unverified candidate (not saved as working output)',
            ),
            SelectableText(controller.candidate!.directory),
          ],
          if (controller.stale)
            const Text('Approval changed. Request a new proposal.'),
          if (!controller.busy)
            TextButton(
              onPressed: controller.refreshApproval,
              child: const Text('Refresh approval'),
            ),
          if (evidence != null) ...[
            const Divider(),
            Text(
              'Task ${evidence.boardTaskId} · Plan message ${evidence.approval.messageIndex + 1}',
            ),
            Text(
              'Approved ${evidence.approval.recordedAt.toUtc().toIso8601String()}',
            ),
            SelectableText(evidence.proposal.summary),
            if (!controller.candidateSupported)
              const Text('Candidate preparation requires a native filesystem.')
            else ...[
              TextButton(
                onPressed: controller.busy
                    ? null
                    : controller.selectCandidateParent,
                child: const Text('Select candidate parent folder'),
              ),
              if (controller.candidateParent != null) ...[
                SelectableText(controller.candidateParent!),
                const Text(
                  'Prepare creates a new subfolder here containing the reviewed '
                  'replacements and recorded source. It does not run code. '
                  'Failed or cancelled copies may remain for inspection.',
                ),
                FilledButton(
                  onPressed: controller.busy
                      ? null
                      : controller.prepareCandidate,
                  child: const Text('Prepare unverified candidate'),
                ),
              ],
            ],
            for (final change in evidence.proposal.changes) ...[
              const Divider(),
              SelectableText(
                change.path,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              SourceDiffView(diff: change.diff),
              const Text('Original (full file)'),
              SelectableText(change.before),
              const SizedBox(height: 12),
              const Text('Proposed replacement (full file)'),
              SelectableText(change.after),
            ],
          ],
        ],
      ),
    );
  }
}
