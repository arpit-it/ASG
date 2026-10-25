import 'package:flutter/material.dart';

import '../controllers/source_review_controller.dart';
import '../models/source_generation.dart';
import 'source_diff_view.dart';
import 'source_candidate_view.dart';
import 'repair_history_view.dart';

class SourceReviewScreen extends StatefulWidget {
  const SourceReviewScreen({super.key, required this.controller});
  final SourceReviewController controller;
  @override
  State<SourceReviewScreen> createState() => _SourceReviewScreenState();
}

class _SourceReviewScreenState extends State<SourceReviewScreen>
    with WidgetsBindingObserver {
  String? taskId;
  Object? repairConsentProposal;
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
    return PopScope(
      canPop: !controller.busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('Review source proposal')),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Request a local-model replacement for selected recorded Dart files. '
              'Prepare reviewed replacements in a separate folder with explicit consent. '
              'Candidates are unverified; the working source and preview remain unchanged. '
              'Verification requires explicit consent; promotion is a separate action.',
            ),
            SelectableText(controller.generated.directory),
            const SizedBox(height: 16),
            const Text('Approved board task'),
            for (final task in controller.tasks)
              CheckboxListTile(
                title: Text('${task.id}: ${task.title}'),
                value: taskId == task.id,
                onChanged: controller.busy || controller.promoted
                    ? null
                    : (_) => setState(() => taskId = task.id),
              ),
            const Text('Recorded Dart files (select up to 8)'),
            for (final path in controller.paths)
              CheckboxListTile(
                title: Text(path),
                value: selected.contains(path),
                onChanged: controller.busy || controller.promoted
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
                      controller.promoted ||
                      taskId == null ||
                      selected.isEmpty ||
                      selected.length > 8
                  ? null
                  : () => controller.request(taskId!, selected.toList()),
              child: const Text('Request source proposal'),
            ),
            if (controller.busy &&
                !(controller.candidateSession?.busy ?? false)) ...[
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
              Text(
                controller.promoted
                    ? 'Working source folder (promoted candidate)'
                    : controller.candidate!.phase == SourceGenerationPhase.ready
                    ? 'Verified candidate folder (awaiting promotion)'
                    : 'Retained candidate folder (separate from working output)',
              ),
              SelectableText(controller.candidate!.directory),
            ],
            if (controller.candidateSession != null &&
                (!controller.reviewBusy || controller.candidateSession!.busy))
              SourceCandidateView(
                key: ObjectKey(controller.candidateSession),
                controller: controller.candidateSession!,
              ),
            if (controller.hasRepairFailure) ...[
              const Text(
                'Request a correction using this saved failure and selected Dart files. '
                'Review the new diff before preparing a separate candidate. '
                'This does not apply edits or rerun checks automatically.',
              ),
              FilledButton(
                onPressed:
                    !controller.canRequestRepair ||
                        selected.isEmpty ||
                        selected.length > 8
                    ? null
                    : () => controller.requestRepair(selected.toList()),
                child: const Text('Request repair proposal from saved failure'),
              ),
            ],
            if (controller.repairBlockedReason != null)
              Text(controller.repairBlockedReason!),
            RepairHistoryView(
              attempts: controller.repairHistory,
              error: controller.repairHistoryError,
              usage: controller.repairUsage,
              usesCurrentApproval: controller.repairUsesCurrentApproval,
            ),
            if (controller.stale)
              const Text(
                'Approval or working build changed. Return to Build and reopen source review.',
              ),
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
                const Text(
                  'Candidate preparation requires a native filesystem.',
                )
              else ...[
                TextButton(
                  onPressed: controller.busy || controller.promoted
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
                    onPressed: controller.busy || controller.promoted
                        ? null
                        : controller.prepareCandidate,
                    child: const Text('Prepare unverified candidate'),
                  ),
                  if (evidence.repairRun != null &&
                      controller.publishCandidate != null) ...[
                    const Text(
                      'Apply repair creates a separate copy of this reviewed diff, '
                      'then automatically runs offline resolve, analysis, tests and '
                      'web build in the macOS sandbox. Each command has a 3-minute '
                      'deadline and 64 KiB output limit. Only the candidate and '
                      'temporary files may be written; SDK and cached packages '
                      'are read-only, with loopback networking only. '
                      'Working output stays active until explicit promotion. '
                      'This action makes no further model requests.',
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'I approve applying this repair and confined checks',
                      ),
                      value: identical(repairConsentProposal, evidence),
                      onChanged: controller.busy || controller.promoted
                          ? null
                          : (value) => setState(() {
                              repairConsentProposal = value == true
                                  ? evidence
                                  : null;
                            }),
                    ),
                    FilledButton(
                      onPressed:
                          controller.canApplyRepair &&
                              identical(repairConsentProposal, evidence)
                          ? () {
                              setState(() => repairConsentProposal = null);
                              controller.applyReviewedRepair(approved: true);
                            }
                          : null,
                      child: const Text(
                        'Apply reviewed repair and rerun checks',
                      ),
                    ),
                  ],
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
      ),
    );
  }
}
