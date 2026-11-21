// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/imported_commit_copy_controller.dart';
import '../models/imported_commit_copy_record.dart';
import '../models/imported_commit_copy_request.dart';

class ImportedCommitCopyScreen extends StatefulWidget {
  const ImportedCommitCopyScreen({
    super.key,
    required this.controller,
    this.onRecheck,
    this.onPropose,
  });
  final ImportedCommitCopyController controller;
  final ValueChanged<ImportedCommitCopyRecord>? onRecheck;
  final ValueChanged<ImportedCommitCopyRecord>? onPropose;
  @override
  State<ImportedCommitCopyScreen> createState() =>
      _ImportedCommitCopyScreenState();
}

class _ImportedCommitCopyScreenState extends State<ImportedCommitCopyScreen> {
  final _destination = TextEditingController();
  ImportedCommitCopyController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    unawaited(c.load());
  }

  @override
  void didUpdateWidget(covariant ImportedCommitCopyScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, c)) {
      old.controller.dispose();
      _destination.clear();
      unawaited(c.load());
    }
  }

  @override
  void dispose() {
    _destination.dispose();
    c.dispose();
    super.dispose();
  }

  Future<void> _pick() async {
    final owner = c;
    final value = await owner.pickDestination();
    if (mounted && identical(owner, c) && !owner.isDisposed && value != null) {
      _destination.text = value;
    }
  }

  List<Widget> _identity(ImportedCommitCopyRequest request) => [
    SelectableText('Source folder: ${request.root}'),
    SelectableText('Original commit: ${request.commit}'),
    SelectableText('Commit tree: ${request.tree}'),
    SelectableText(
      'Manifest SHA-256: ${request.manifestDigest} (${request.manifestFiles} files)',
    ),
    SelectableText('Context SHA-256: ${request.contextDigest}'),
    SelectableText('Plan SHA-256: ${request.planDigest}'),
    SelectableText('Proposal SHA-256: ${request.proposalDigest}'),
    SelectableText('Saved proposal SHA-256: ${request.historyDigest}'),
    SelectableText('Destination parent: ${request.destination}'),
    SelectableText('Trusted Python: ${request.python}'),
    SelectableText('Attempt: ${request.attemptId}'),
  ];
  Future<void> _prepare() async {
    final owner = c, request = c.draft;
    if (request == null || !owner.canPrepare) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Create original commit copy?'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._identity(request),
            const Text(
              'Create a fresh private run in this existing parent folder containing all original committed files, including nonselected and binary files. The proposed replacement is NOT applied. Limits: 2048 files, 2 MiB per file, 24 MiB total; unsupported input is refused without truncation. Source files, index, refs and existing outputs are preserved. Only bundled tools and bounded Git reads run. No repository-authored commands, builds, model sharing or execution are authorized. App history stores paths and provenance, up to 16 attempts / 512 KiB, and retains uncertain runs for inspection.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Create copy'),
          ),
        ],
      ),
    );
    if (confirmed == true &&
        mounted &&
        identical(owner, c) &&
        !owner.isDisposed) {
      await owner.prepare(request);
    }
  }

  Future<void> _acknowledge() async {
    final owner = c, record = c.history;
    if (record == null || !owner.canAcknowledge) return;
    var checked = false;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setLocal) => AlertDialog(
          title: const Text('Confirm recovery inspection'),
          scrollable: true,
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'An earlier copy may have created files even if its result was lost. Inspect this destination and establish that the previous worker has stopped. A newly opened app cannot prove old process ownership. Do not terminate a process using only a saved PID. This acknowledgement never replays a copy or promotes an uncertain receipt.',
              ),
              if (record.latest != null) ..._identity(record.latest!.request),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                value: checked,
                onChanged: (value) => setLocal(() => checked = value ?? false),
                title: const Text(
                  'I inspected the destination and confirmed the previous copy worker has stopped.',
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: checked ? () => Navigator.pop(context, true) : null,
              child: const Text('Acknowledge inspection'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true &&
        mounted &&
        identical(owner, c) &&
        !owner.isDisposed) {
      await owner.acknowledge(record, inspectedAndStopped: true);
    }
  }

  List<Widget> _history(ImportedCommitCopyRecord history) => [
    Text(
      'Retained copy attempts: ${history.attempts.length} / ${ImportedCommitCopyRecord.attemptLimit}',
    ),
    if (history.attempts.isEmpty)
      const Text('No saved baseline-copy attempts for this folder.'),
    if (history.lastPrepared case final saved?) ...[
      const Divider(),
      const Text('Last durably confirmed original copy — historical'),
      const Text(
        'A saved path and fingerprint do not verify current disk contents or grant execution permission. Recheck before any later operation.',
      ),
      SelectableText('Copy path: ${saved.observation!.copyPath}'),
      SelectableText(
        'Whole-copy fingerprint: ${saved.observation!.fingerprint}',
      ),
      SelectableText('Original commit: ${saved.request.commit}'),
      if (widget.onPropose != null)
        OutlinedButton(
          onPressed: c.busy || history.needsRecovery
              ? null
              : () => widget.onPropose!(history),
          child: const Text('Review isolated proposed copy'),
        ),
      if (widget.onRecheck != null)
        OutlinedButton(
          onPressed: c.busy || history.needsRecovery
              ? null
              : () => widget.onRecheck!(history),
          child: const Text('Review current copy recheck'),
        ),
    ],
    for (final attempt in history.attempts.reversed)
      ExpansionTile(
        key: ValueKey(attempt.request.attemptId),
        title: Text(
          'Copy attempt: ${attempt.phase.name}${attempt.acknowledgedAt == null ? '' : ' · inspection acknowledged'}',
        ),
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ..._identity(attempt.request),
                SelectableText(
                  'Started: ${attempt.startedAt.toIso8601String()}',
                ),
                if (attempt.finishedAt != null)
                  SelectableText(
                    'Recorded finish: ${attempt.finishedAt!.toIso8601String()}',
                  ),
                if (attempt.acknowledgedAt != null)
                  SelectableText(
                    'Inspection acknowledged: ${attempt.acknowledgedAt!.toIso8601String()}',
                  ),
                if (attempt.observation case final result?) ...[
                  Text(
                    'Receipt status: ${result.status.name}; ${result.reason ?? 'original copy observed'}',
                  ),
                  if (result.runName != null)
                    SelectableText(
                      'Reported run for inspection: ${result.reportedRun(attempt.request)}',
                    ),
                  if (result.fingerprint != null)
                    SelectableText(
                      'Observed fingerprint: ${result.fingerprint}',
                    ),
                  if (attempt.phase != ImportedCommitCopyPhase.prepared)
                    const Text(
                      'Recovery evidence only. This receipt was not promoted to confirmed success.',
                    ),
                ],
              ],
            ),
          ),
        ],
      ),
  ];
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final history = c.history, draft = c.draft, proposal = c.currentProposal;
      return Scaffold(
        appBar: AppBar(
          title: Text(
            c.historyOnly
                ? 'Saved baseline-copy history'
                : 'Prepare immutable baseline copy',
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Prepare the original committed baseline in a fresh private output. This does not apply the proposed edit or grant build, repository-command, model-sharing or execution permission. Working files and conflicts remain unknown.',
            ),
            SelectableText('Source folder: ${c.root}'),
            if (!c.host.supported)
              const Text(
                'Preparing baseline copies is unavailable on this platform. Saved history remains readable.',
              ),
            if (c.busy) const LinearProgressIndicator(),
            if (c.error != null) SelectableText(c.error!),
            if (c.workerBlocked)
              const Text(
                'Another source worker owns cleanup. Wait for confirmed cleanup or reconcile that worker before preparing a copy.',
              ),
            if (c.cleanupUncertain)
              const Text(
                'Worker cleanup is unconfirmed. Shared ownership is retained; reconcile the worker before reopening.',
              ),
            if (!c.historyOnly) ...[
              if (proposal != null) ...[
                SelectableText(
                  'Current saved original commit: ${proposal.context.commit}',
                ),
                SelectableText('Current reviewed plan: ${proposal.plan.text}'),
              ],
              TextField(
                controller: _destination,
                enabled: !c.busy && c.host.supported,
                onChanged: (_) => c.invalidateDraft(),
                decoration: const InputDecoration(
                  labelText: 'Existing destination folder',
                  helperText: 'Paste its full path. A fresh private run is created here.',
                  helperMaxLines: 3,
                ),
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: c.canPick ? _pick : null,
                    child: const Text('Choose folder'),
                  ),
                  FilledButton(
                    onPressed: c.canReview
                        ? () => c.review(_destination.text)
                        : null,
                    child: const Text('Review original copy'),
                  ),
                  FilledButton(
                    onPressed: c.canPrepare ? _prepare : null,
                    child: const Text('Prepare original copy'),
                  ),
                ],
              ),
              if (draft != null) ...[
                const Divider(),
                Text(
                  c.stale
                      ? 'Previous copy review — stale'
                      : 'Reviewed original-copy intent',
                ),
                ..._identity(draft),
              ],
            ],
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                OutlinedButton(
                  onPressed: c.busy ? null : c.load,
                  child: const Text('Reload copy inputs and history'),
                ),
                if (c.canStop)
                  FilledButton(
                    onPressed: c.stop,
                    child: const Text('Stop copy'),
                  ),
                if (c.canAcknowledge)
                  OutlinedButton(
                    onPressed: _acknowledge,
                    child: const Text('Confirm recovery inspection'),
                  ),
              ],
            ),
            if (history?.needsRecovery ?? false)
              const Text(
                'An unresolved attempt blocks new copies. Inspect its destination and confirm the old worker stopped before acknowledging recovery.',
              ),
            if (history != null &&
                history.attempts.length >=
                    ImportedCommitCopyRecord.attemptLimit)
              const Text(
                'Copy history limit reached. Retained attempts and outputs have not been removed.',
              ),
            if (c.reported case final receipt?)
              if (draft != null &&
                  receipt.requestDigest == draft.digest &&
                  history?.latest?.phase !=
                      ImportedCommitCopyPhase.prepared) ...[
                const Text(
                  'Receipt awaiting durable confirmation — recovery evidence only.',
                ),
                if (receipt.runName != null)
                  SelectableText('Reported run: ${receipt.reportedRun(draft)}'),
              ],
            if (history != null) ..._history(history),
          ],
        ),
      );
    },
  );
}
