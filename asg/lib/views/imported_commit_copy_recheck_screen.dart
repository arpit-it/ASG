// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/imported_commit_copy_recheck_controller.dart';
import '../models/imported_commit_copy_recheck.dart';

class ImportedCommitCopyRecheckScreen extends StatefulWidget {
  const ImportedCommitCopyRecheckScreen({super.key, required this.controller});
  final ImportedCommitCopyRecheckController controller;
  @override
  State<ImportedCommitCopyRecheckScreen> createState() =>
      _ImportedCommitCopyRecheckScreenState();
}

class _ImportedCommitCopyRecheckScreenState
    extends State<ImportedCommitCopyRecheckScreen> {
  ImportedCommitCopyRecheckController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    unawaited(c.load());
  }

  @override
  void didUpdateWidget(covariant ImportedCommitCopyRecheckScreen old) {
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

  List<Widget> identity(ImportedCommitCopyRecheckRequest request) => [
    SelectableText('Original source: ${request.root}'),
    SelectableText('Saved copy: ${request.copyPath}'),
    SelectableText('Original commit: ${request.commit}'),
    SelectableText('Commit tree: ${request.tree}'),
    SelectableText(
      'Expected whole-copy fingerprint: ${request.expectedFingerprint}',
    ),
    SelectableText('Saved copy history SHA-256: ${request.historyDigest}'),
    SelectableText('Saved copy request SHA-256: ${request.copyRequestDigest}'),
    SelectableText('Saved copy receipt SHA-256: ${request.copyReceiptDigest}'),
    SelectableText('Current trusted Python: ${request.python}'),
    SelectableText('Recheck: ${request.recheckId}'),
  ];
  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Recheck saved original copy')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Read the complete saved copy without changing files or history. This checks all bounded file bytes, executable bits and directory names, including nonselected files. Both incomplete-copy markers must be absent. No Git, repository commands, builds or model requests run.',
          ),
          const Text(
            'A matching result is a dated content observation. It does not prove origin or physical lineage, revive approval, or grant editing or execution permission.',
          ),
          if (!c.host.supported)
            const Text(
              'Native copy rechecks are unavailable on this platform. Saved copy history remains readable.',
            ),
          if (c.busy) const LinearProgressIndicator(),
          if (c.error != null) SelectableText(c.error!),
          if (c.workerBlocked)
            const Text(
              'Another source worker owns cleanup. New reads wait for confirmed cleanup.',
            ),
          if (c.cleanupUncertain)
            const Text(
              'Worker cleanup is unconfirmed; shared ownership is retained.',
            ),
          if (c.request case final request?) ...identity(request),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton(
                onPressed: c.busy ? null : c.load,
                child: const Text('Reload copy review'),
              ),
              FilledButton(
                onPressed: c.canRecheck
                    ? () {
                        final owner = c, request = c.request!;
                        unawaited(owner.recheck(request));
                      }
                    : null,
                child: const Text('Recheck current copy'),
              ),
              if (c.canStop)
                FilledButton(
                  onPressed: c.stop,
                  child: const Text('Stop recheck'),
                ),
            ],
          ),
          if (c.stale && c.request != null)
            const Text('Reviewed inputs changed. Reload before rechecking.'),
          if (c.result?.status == ImportedCommitCopyRecheckStatus.refused &&
              c.lastObserved != null) ...[
            const Divider(),
            const Text('Previous completed content observation — historical'),
            SelectableText(
              'Previous observed copy: ${c.lastObserved!.copyPath}',
            ),
            SelectableText(
              'Previous fingerprint: ${c.lastObserved!.observedFingerprint}',
            ),
            SelectableText(
              'Previous observation: ${c.lastObserved!.status.name} at ${c.lastObserved!.recordedAt.toIso8601String()}',
            ),
          ],
          if (c.result case final result?) ...[
            const Divider(),
            Text(
              c.resultCurrent
                  ? 'Dated recheck observation'
                  : 'Previous observation — historical',
            ),
            Text('Copy observation: ${result.status.name}'),
            SelectableText(
              'Observed at: ${result.recordedAt.toIso8601String()}',
            ),
            SelectableText('Observed copy: ${result.copyPath}'),
            if (result.observedFingerprint != null)
              SelectableText(
                'Observed whole-copy fingerprint: ${result.observedFingerprint} (${result.files} files, ${result.bytes} bytes)',
              ),
            if (result.reason != null)
              Text('Observation unavailable: ${result.reason}'),
            const Text(
              'Contents can change after reading. Recheck at each later operation; this observation grants no mutation or execution authority.',
            ),
          ],
        ],
      ),
    ),
  );
}
