// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter/material.dart';

import '../controllers/imported_source_baseline_controller.dart';
import '../models/project_source_observation.dart';

class ImportedSourceBaselineScreen extends StatefulWidget {
  const ImportedSourceBaselineScreen({super.key, required this.controller});
  final ImportedSourceBaselineController controller;
  @override
  State<ImportedSourceBaselineScreen> createState() =>
      _ImportedSourceBaselineScreenState();
}

class _ImportedSourceBaselineScreenState
    extends State<ImportedSourceBaselineScreen> {
  ImportedSourceBaselineController get c => widget.controller;
  @override
  void didUpdateWidget(covariant ImportedSourceBaselineScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, c)) old.controller.dispose();
  }

  @override
  void dispose() {
    c.dispose();
    super.dispose();
  }

  Future<void> _recheck() async {
    final owner = c;
    await owner.recheck(
      confirm: (ProjectSourceReadRequest request) async {
        if (!mounted || !identical(owner, c) || owner.isDisposed) return false;
        return await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Read captured files again?'),
                content: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Read only these selected files through the packaged contained reader. No source files are changed, no project commands or model requests run, and no result is saved. A point-in-time byte match grants no editing or current approval.',
                      ),
                      SelectableText('Folder: ${request.root}'),
                      SelectableText('Configured Python: ${request.python}'),
                      for (final path in request.selectedPaths) Text(path),
                      const Text(
                        '1–4 selected Dart files; 32 KiB each / 64 KiB total. Stop waits for owned cleanup.',
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: const Text('Read selected files'),
                  ),
                ],
              ),
            ) ??
            false;
      },
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final result = c.comparison;
      return Scaffold(
        appBar: AppBar(title: const Text('Recheck captured source baseline')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Compare every captured file with a fresh contained read. This is a transient point-in-time observation, not current-disk proof, plan approval or permission to write or execute. Saved history is preserved.',
            ),
            SelectableText('Folder: ${c.saved.root}'),
            SelectableText('Saved comparison SHA-256: ${c.saved.digest}'),
            for (final file in c.saved.context.files)
              SelectableText('Captured file: ${file.path}'),
            if (!c.supported)
              const Text(
                'Contained source reads are unavailable on this host. Historical comparison remains available.',
              ),
            if (c.blockedByOtherRead)
              const Text(
                'An earlier source read still owns cleanup. Retry after it finishes; uncertain cleanup requires reconciliation.',
              ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: c.canRecheck ? _recheck : null,
                  child: const Text('Recheck captured files'),
                ),
                OutlinedButton(
                  onPressed: c.canStop ? c.cancel : null,
                  child: const Text('Stop'),
                ),
              ],
            ),
            if (c.busy) const LinearProgressIndicator(),
            if (c.confirming) const Text('Waiting for read consent.'),
            if (c.error != null)
              Text(
                c.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (result != null) ...[
              const Divider(),
              Text(
                c.stale
                    ? 'Previous baseline result — stale'
                    : 'Captured baseline result — unverified',
              ),
              Text('Point-in-time result: ${result.status.name}'),
              SelectableText(
                'App observation time: ${result.observedAt.toIso8601String()}',
              ),
              const Text(
                'This observation remains unverified. Files can change after a read; matching bytes do not grant editing permission or approve a plan.',
              ),
              SelectableText('Read request SHA-256: ${result.requestDigest}'),
              SelectableText(
                'Observation SHA-256: ${result.observationDigest}',
              ),
              for (final file in result.files) ...[
                Text(
                  '${file.path}: ${file.matches ? "matched captured bytes" : "changed bytes"}',
                ),
                SelectableText(
                  'Before: ${file.beforeHash} (${file.beforeByteLength} bytes)',
                ),
                SelectableText(
                  'Observed: ${file.afterHash ?? "not observed"} (${file.afterByteLength ?? 0} bytes)',
                ),
              ],
            ],
          ],
        ),
      );
    },
  );
}
