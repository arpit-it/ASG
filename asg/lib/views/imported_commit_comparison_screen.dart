// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter/material.dart';

import '../controllers/imported_commit_comparison_controller.dart';
import '../models/imported_commit_source_observation.dart';
import '../models/imported_commit_context.dart';
import '../models/project_inspection.dart';

class ImportedCommitComparisonScreen extends StatefulWidget {
  const ImportedCommitComparisonScreen({
    super.key,
    required this.controller,
    this.inspection,
    this.onPlan,
  });
  final ImportedCommitComparisonController controller;
  final ProjectInspection? inspection;
  final void Function(ImportedCommitContext)? onPlan;
  @override
  State<ImportedCommitComparisonScreen> createState() =>
      _ImportedCommitComparisonScreenState();
}

class _ImportedCommitComparisonScreenState
    extends State<ImportedCommitComparisonScreen> {
  ImportedCommitComparisonController get c => widget.controller;
  late final TextEditingController _commit;
  @override
  void initState() {
    super.initState();
    _commit = TextEditingController(text: c.commit);
  }

  @override
  void didUpdateWidget(covariant ImportedCommitComparisonScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, c)) {
      old.controller.dispose();
      _commit.text = c.commit;
    }
  }

  @override
  void dispose() {
    c.dispose();
    _commit.dispose();
    super.dispose();
  }

  Future<void> _recheck() async {
    final owner = c;
    await owner.recheck(
      confirm: (ImportedCommitReadRequest request) async {
        if (!mounted || !identical(owner, c) || owner.isDisposed) return false;
        return await showDialog<bool>(
              context: context,
              builder: (context) => AlertDialog(
                title: const Text('Read selected commit content?'),
                content: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Text(
                        'Read the selected file content from this exact commit and inspect its complete bounded tree metadata. Working files, index, refs and saved history stay unchanged. No model requests or project commands run. No result is saved. Matching captured bytes grants no copying, editing or plan approval.',
                      ),
                      SelectableText('Folder: ${request.root}'),
                      SelectableText('Commit: ${request.commit}'),
                      SelectableText('Configured Python: ${request.python}'),
                      for (final path in request.selectedPaths) Text(path),
                      const Text(
                        '1–4 selected Dart files; 32 KiB each / 64 KiB total. Commit tree metadata: up to 2048 files and 128 directories. A simple direct Git layout is required. Stop waits for owned cleanup.',
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
                    child: const Text('Read commit content'),
                  ),
                ],
              ),
            ) ??
            false;
      },
    );
  }

  Future<void> _preparePlanning() async {
    final owner = c;
    final inspection = widget.inspection;
    final onPlan = widget.onPlan;
    if (inspection == null) return;
    final captured = await owner.preparePlanning(inspection);
    if (mounted &&
        identical(owner, c) &&
        !owner.isDisposed &&
        captured != null &&
        identical(inspection, widget.inspection) &&
        identical(onPlan, widget.onPlan)) {
      onPlan?.call(captured);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final result = c.comparison;
      return Scaffold(
        appBar: AppBar(
          title: const Text('Compare captured files with a commit'),
        ),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Compare every file in saved history with content from a selected immutable commit. This does not establish current working files, clean repository state, plan approval or permission to copy, write or execute. Saved history is preserved. The result is temporary.',
            ),
            SelectableText('Folder: ${c.saved.root}'),
            SelectableText('Saved comparison SHA-256: ${c.saved.digest}'),
            for (final file in c.saved.context.files)
              SelectableText('Captured file: ${file.path}'),
            if (!c.supported)
              const Text(
                'Immutable commit reads are unavailable on this host. Historical comparison remains available.',
              ),
            if (c.blockedByOtherRead)
              const Text(
                'An earlier source read still owns cleanup. Retry after it finishes; uncertain cleanup requires reconciliation.',
              ),
            TextField(
              controller: _commit,
              onChanged: c.setCommit,
              enabled: !c.cleanupUncertain,
              decoration: const InputDecoration(
                labelText: 'Full commit ID',
                helperMaxLines: 3,
                helperText: '40 lowercase hexadecimal characters; no branch names or revision expressions.',
              ),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: c.canRecheck ? _recheck : null,
                  child: const Text('Compare with commit'),
                ),
                OutlinedButton(
                  onPressed: c.canStop ? c.cancel : null,
                  child: const Text('Stop'),
                ),
              ],
            ),
            if (widget.inspection != null && widget.onPlan != null)
              OutlinedButton(
                onPressed: c.canPreparePlanning ? _preparePlanning : null,
                child: const Text('Review committed source and plan'),
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
                    ? 'Previous commit comparison — stale'
                    : 'Captured vs committed result — unverified',
              ),
              Text('Captured vs selected commit: ${result.status.name}'),
              SelectableText('Compared commit: ${result.request.commit}'),
              SelectableText('Commit tree: ${result.observation.tree}'),
              SelectableText(
                'Manifest SHA-256: ${result.observation.manifestDigest} (${result.observation.manifestFiles} files)',
              ),
              SelectableText(
                'App observation time: ${result.observedAt.toIso8601String()}',
              ),
              const Text(
                'This compares a historical capture with selected commit data. Current working files and conflicts remain unknown. No copying, editing or execution permission is granted.',
              ),
              SelectableText('Commit request SHA-256: ${result.requestDigest}'),
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
                  'Committed: ${file.afterHash ?? "not observed"} (${file.afterByteLength ?? 0} bytes)',
                ),
              ],
            ],
          ],
        ),
      );
    },
  );
}
