// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/imported_commit_edit_controller.dart';
import '../models/imported_commit_edit_record.dart';
import '../models/imported_commit_edit_request.dart';
import 'source_diff_view.dart';

class ImportedCommitEditScreen extends StatefulWidget {
  const ImportedCommitEditScreen({
    super.key,
    required this.controller,
    this.onCompare,
  });
  final ImportedCommitEditController controller;
  final void Function(ImportedCommitEditRecord)? onCompare;
  @override
  State<ImportedCommitEditScreen> createState() =>
      _ImportedCommitEditScreenState();
}

class _ImportedCommitEditScreenState extends State<ImportedCommitEditScreen> {
  final _destination = TextEditingController();
  ImportedCommitEditController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    unawaited(c.load());
  }

  @override
  void didUpdateWidget(covariant ImportedCommitEditScreen old) {
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

  List<Widget> _identity(ImportedCommitEditRequest request) => [
    SelectableText('Source folder: ${request.root}'),
    SelectableText('Original copy: ${request.sourceCopy}'),
    SelectableText(
      'Original copy fingerprint: ${request.expectedSourceFingerprint}',
    ),
    SelectableText('Copy history SHA-256: ${request.copyHistoryDigest}'),
    SelectableText('Selected file: ${request.selectedPath} (${request.mode})'),
    SelectableText('Before SHA-256: ${request.beforeHash}'),
    SelectableText('Replacement SHA-256: ${request.afterHash}'),
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
        title: const Text('Create isolated proposed copy?'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ..._identity(request),
            const Text(
              'Create a fresh private output containing all bounded committed-copy files, including nonselected and binary data, with exactly this one reviewed replacement. The original repository, original copy and earlier outputs are preserved. File executable mode, BOM presence and supported legal header are preserved. Limits: 2048 files, 2 MiB per file, 24 MiB total; unsupported input is refused without truncation. Only bundled tools and bounded config-disabled Git metadata reads run. No repository-authored commands, builds, tests, model sharing or execution are authorized. App history retains the reviewed replacement, paths and provenance up to 16 attempts / 1 MiB; uncertain outputs remain for inspection.',
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
            child: const Text('Create proposed copy'),
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

  List<Widget> _history(ImportedCommitEditRecord history) => [
    Text(
      'Retained copy attempts: ${history.attempts.length} / ${ImportedCommitEditRecord.attemptLimit}',
    ),
    if (history.attempts.isEmpty)
      const Text('No saved proposed-copy attempts for this folder.'),
    if (history.lastPrepared case final saved?) ...[
      const Divider(),
      const Text('Last durably confirmed proposed copy — historical'),
      const Text(
        'A saved path and fingerprint do not verify current disk contents or grant execution permission. Recheck before any later operation.',
      ),
      SelectableText('Copy path: ${saved.observation!.copyPath}'),
      SelectableText(
        'Whole-copy fingerprint: ${saved.observation!.fingerprint}',
      ),
      SelectableText('Original commit: ${saved.request.commit}'),
      if (widget.onCompare != null)
        OutlinedButton.icon(
          onPressed: !c.busy && !history.needsRecovery
              ? () => widget.onCompare!(history)
              : null,
          icon: const Icon(Icons.compare_arrows),
          label: const Text('Compare saved proposed copy'),
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
                  if (attempt.phase != ImportedCommitEditPhase.prepared)
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
                ? 'Saved proposed-copy history'
                : 'Prepare isolated proposed copy',
          ),
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Review the current approved replacement against a fresh full read of the saved original copy. Creation writes only a separately isolated proposed copy after confirmation; it grants no build, repository-command, model-sharing or execution permission. Original working files and conflicts remain unknown.',
            ),
            SelectableText('Source folder: ${c.root}'),
            if (!c.host.supported)
              const Text(
                'Preparing proposed copies is unavailable on this platform. Saved history remains readable.',
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
                  'Current saved proposal commit: ${proposal.context.commit}',
                ),
                SelectableText('Current reviewed plan: ${proposal.plan.text}'),
                SourceDiffView(diff: proposal.proposal.diff),
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
                    child: const Text('Review proposed copy'),
                  ),
                  FilledButton(
                    onPressed: c.canPrepare ? _prepare : null,
                    child: const Text('Prepare proposed copy'),
                  ),
                ],
              ),
              if (draft != null) ...[
                const Divider(),
                Text(
                  c.stale
                      ? 'Previous proposed-copy review — stale'
                      : 'Reviewed proposed-copy intent',
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
                  child: const Text('Reload proposal inputs and history'),
                ),
                if (c.canStop)
                  FilledButton(
                    onPressed: c.stop,
                    child: Text(c.reviewing ? 'Stop review' : 'Stop copy'),
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
                    ImportedCommitEditRecord.attemptLimit)
              const Text(
                'Copy history limit reached. Retained attempts and outputs have not been removed.',
              ),
            if (c.reported case final receipt?)
              if (draft != null &&
                  receipt.requestDigest == draft.digest &&
                  history?.latest?.phase !=
                      ImportedCommitEditPhase.prepared) ...[
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
