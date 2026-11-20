// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/imported_source_proposal_controller.dart';
import 'source_diff_view.dart';

class ImportedSourceProposalScreen extends StatefulWidget {
  const ImportedSourceProposalScreen({super.key, required this.controller});
  final ImportedSourceProposalController controller;
  @override
  State<ImportedSourceProposalScreen> createState() =>
      _ImportedSourceProposalScreenState();
}

class _ImportedSourceProposalScreenState
    extends State<ImportedSourceProposalScreen> {
  final _replacement = TextEditingController();
  late String _path;
  ImportedSourceProposalController get c => widget.controller;
  void _reset() {
    _path = c.context.files.first.path;
    _replacement.text = c.context.files.first.text;
    unawaited(c.load());
  }

  @override
  void initState() {
    super.initState();
    _reset();
  }

  @override
  void didUpdateWidget(covariant ImportedSourceProposalScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, c)) {
      old.controller.dispose();
      _reset();
    }
  }

  @override
  void dispose() {
    _replacement.dispose();
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final proposal = c.proposal;
      return Scaffold(
        appBar: AppBar(title: const Text('Read-only source proposal')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Author proposed replacement contents for one captured file. This comparison is transient: no proposal is saved, no files are read or changed, and no model or commands run. A reviewed plan is not write or execution permission.',
            ),
            SelectableText('Folder: ${c.inspection.root}'),
            SelectableText('Captured context SHA-256: ${c.context.digest}'),
            if (c.plan != null)
              SelectableText('Reviewed plan: ${c.plan!.text}'),
            DropdownButtonFormField<String>(
              key: ObjectKey(c),
              initialValue: _path,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Captured source file',
              ),
              items: [
                for (final file in c.context.files)
                  DropdownMenuItem(value: file.path, child: Text(file.path)),
              ],
              onChanged: c.busy
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _path = value;
                        _replacement.text = c.context.files
                            .singleWhere((f) => f.path == value)
                            .text;
                      });
                      c.invalidateDraft();
                    },
            ),
            TextField(
              controller: _replacement,
              enabled: !c.busy,
              minLines: 6,
              maxLines: 14,
              decoration: const InputDecoration(
                labelText: 'Proposed contents (transient)',
                helperText: '16 KiB UTF-8 / 500 lines. Oversized input is refused, never truncated.',
              ),
              onChanged: (_) => c.invalidateDraft(),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                FilledButton(
                  onPressed: c.canPreview
                      ? () => c.preview(_path, _replacement.text)
                      : null,
                  child: const Text('Preview read-only diff'),
                ),
                OutlinedButton(
                  onPressed: c.busy ? null : c.load,
                  child: const Text('Reload reviewed plan'),
                ),
              ],
            ),
            if (c.busy) const LinearProgressIndicator(),
            if (c.error != null)
              Text(
                c.error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (proposal != null) ...[
              const Divider(),
              Text(
                c.stale
                    ? 'Previous comparison — stale'
                    : 'Captured comparison — unverified',
              ),
              const Text(
                'Historical captured bytes and app inputs only. This is not current-disk verification, an apply patch or execution approval.',
              ),
              SelectableText('File: ${proposal.source.path}'),
              SelectableText('Plan SHA-256: ${proposal.planDigest}'),
              SelectableText('Before SHA-256: ${proposal.source.digest}'),
              SelectableText('After SHA-256: ${proposal.afterHash}'),
              SelectableText('Proposal SHA-256: ${proposal.digest}'),
              SourceDiffView(diff: proposal.diff),
            ],
          ],
        ),
      );
    },
  );
}
