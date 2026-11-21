// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/imported_commit_edit_comparison_controller.dart';
import '../models/imported_commit_edit_comparison.dart';

class ImportedCommitEditComparisonScreen extends StatefulWidget {
  const ImportedCommitEditComparisonScreen({
    super.key,
    required this.controller,
  });
  final ImportedCommitEditComparisonController controller;
  @override
  State<ImportedCommitEditComparisonScreen> createState() =>
      _ImportedCommitEditComparisonScreenState();
}

class _ImportedCommitEditComparisonScreenState
    extends State<ImportedCommitEditComparisonScreen> {
  ImportedCommitEditComparisonController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    unawaited(c.load());
  }

  @override
  void didUpdateWidget(covariant ImportedCommitEditComparisonScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, c)) {
      old.controller.dispose();
      unawaited(c.load());
    }
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  List<Widget> _identity(ImportedCommitEditComparisonRequest r) => [
    SelectableText('Original source folder: ${r.root}'),
    SelectableText('Saved original copy: ${r.originalCopy}'),
    SelectableText('Saved proposed copy: ${r.proposedCopy}'),
    SelectableText('Original commit: ${r.commit}'),
    SelectableText(
      'Expected original fingerprint: ${r.expectedOriginalFingerprint}',
    ),
    SelectableText(
      'Expected proposed fingerprint: ${r.expectedProposedFingerprint}',
    ),
    SelectableText('Original-copy history SHA-256: ${r.copyHistoryDigest}'),
    SelectableText('Proposed-copy history SHA-256: ${r.editHistoryDigest}'),
    SelectableText('Selected replacement: ${r.selectedPath}'),
    SelectableText('Current trusted Python: ${r.python}'),
    SelectableText('Comparison: ${r.comparisonId}'),
  ];
  List<Widget> _observation(
    ImportedCommitEditComparisonObservation r, {
    required bool current,
  }) => [
    const Divider(),
    Text(
      '${current ? 'Completed read' : 'Previous read — historical'}: ${r.status.name}',
    ),
    SelectableText('Observed at: ${r.recordedAt.toIso8601String()}'),
    SelectableText('Read request SHA-256: ${r.requestDigest}'),
    if (r.originalFingerprint != null) ...[
      SelectableText('Observed original fingerprint: ${r.originalFingerprint}'),
      SelectableText('Observed proposed fingerprint: ${r.proposedFingerprint}'),
      Text(
        'Original: ${r.originalFiles} files, ${r.originalBytes} bytes. Proposed: ${r.proposedFiles} files, ${r.proposedBytes} bytes.',
      ),
      Text(
        'Selected bytes and executable mode ${r.selectedMatches == true ? 'match the saved replacement' : 'differ from the saved replacement'}.',
      ),
    ],
    if (r.comparison case final value?) ...[
      Text(
        'File changes: ${value.added} added, ${value.modified} modified, ${value.removed} removed, ${value.executableChanged} executable-mode changes.',
      ),
      const Text(
        'File counts omit empty-directory changes. Complete fingerprints include directory names.',
      ),
      for (final change in value.changes)
        SelectableText(
          '${change.kind.name}: ${change.path}${change.executableChanged ? ' (mode changed)' : ''}',
        ),
      if (value.truncated)
        const Text('Change list truncated to the bounded display limit.'),
    ],
    if (r.status == ImportedCommitEditComparisonStatus.refused)
      const Text(
        'No complete current observation was confirmed. Inspect missing, changed or incomplete outputs and resolve recovery before retrying.',
      ),
  ];
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Compare saved proposed copy')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Read both complete saved copies without changing files or history. Compare all bounded file bytes, executable bits and directory names, including nonselected and binary files. All three incomplete-output markers must be absent.',
          ),
          const Text(
            'Reads are bounded to 2048 files, 2 MiB per file and 24 MiB per copy, with a helper deadline. No Git, repository commands, builds, tests or model requests run.',
          ),
          const Text(
            'Matching is a dated content observation. It does not verify the original working tree, prove physical lineage, revive plan approval or grant editing or execution permission. Reload creates a fresh read identity; completed observations are not saved as new approval.',
          ),
          if (!c.host.supported)
            const Text(
              'Native copy comparison is unavailable on this platform. Saved histories remain readable.',
            ),
          if (c.busy) const LinearProgressIndicator(),
          if (c.error != null) SelectableText(c.error!),
          if (c.workerBlocked)
            const Text(
              'Another source worker owns cleanup. Wait for confirmed cleanup before reading.',
            ),
          if (c.cleanupUncertain)
            const Text(
              'Worker cleanup is unconfirmed; shared ownership is retained.',
            ),
          if (c.request case final request?) ..._identity(request),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: c.busy ? null : c.load,
                child: const Text('Reload comparison review'),
              ),
              FilledButton(
                onPressed: c.canCompare
                    ? () {
                        final owner = c, request = c.request!;
                        unawaited(owner.compare(request));
                      }
                    : null,
                child: const Text('Compare current copies'),
              ),
              if (c.canStop)
                FilledButton(
                  onPressed: c.stop,
                  child: const Text('Stop comparison'),
                ),
            ],
          ),
          if (c.stale)
            const Text(
              'Current input selection is unavailable or changed. Reopen history after resolving recovery.',
            ),
          if (c.result case final result?)
            ..._observation(result, current: c.resultCurrent),
          if (c.lastObserved case final previous?)
            if (!identical(previous, c.result))
              ..._observation(previous, current: false),
          const Text(
            'Original copies, proposed outputs, saved journals and last working output are preserved. This read does not authorize another operation.',
          ),
        ],
      ),
    ),
  );
}
