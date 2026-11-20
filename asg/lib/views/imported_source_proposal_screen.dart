// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/imported_source_proposal_controller.dart';
import '../models/imported_source_proposal_record.dart';
import 'source_diff_view.dart';

class ImportedSourceProposalScreen extends StatefulWidget {
  const ImportedSourceProposalScreen({
    super.key,
    required this.controller,
    this.onBaseline,
    this.onCommitComparison,
  });
  final ImportedSourceProposalController controller;
  final ValueChanged<ImportedSourceProposalRecord>? onBaseline;
  final ValueChanged<ImportedSourceProposalRecord>? onCommitComparison;
  @override
  State<ImportedSourceProposalScreen> createState() =>
      _ImportedSourceProposalScreenState();
}

class _ImportedSourceProposalScreenState
    extends State<ImportedSourceProposalScreen> {
  final _replacement = TextEditingController();
  late String _path;
  bool _showSaved = false;
  ImportedSourceProposalController get c => widget.controller;
  void _reset() {
    _showSaved = c.historyOnly;
    _path = c.context?.files.first.path ?? '';
    _replacement.text = c.context?.files.first.text ?? '';
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

  Future<void> _save() async {
    final owner = c, proposal = c.proposal;
    if (proposal == null || !owner.canSave) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save comparison locally?'),
        content: const Text(
          'This stores the captured source text, full reviewed plan and proposed replacement in app records, replacing the previous saved comparison for this folder. The complete saved record must fit 256 KiB; oversized records are refused without truncation. It does not change source files or grant current approval, model sharing or execution permission.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save comparison'),
          ),
        ],
      ),
    );
    if (confirmed != true ||
        !mounted ||
        !identical(owner, c) ||
        owner.isDisposed) {
      return;
    }
    await owner.save(proposal);
    if (mounted &&
        identical(owner, c) &&
        owner.saved?.proposal.matches(proposal) == true) {
      setState(() => _showSaved = true);
    }
  }

  List<Widget> _history(ImportedSourceProposalRecord saved) => [
    const Divider(),
    const Text('Last saved historical comparison — unverified'),
    const Text(
      'Original captured inputs only. Historical plan review is not current approval, disk verification or execution permission.',
    ),
    SelectableText('Saved: ${saved.recordedAt.toIso8601String()}'),
    SelectableText('Historical reviewed plan: ${saved.plan.text}'),
    SelectableText('Historical file: ${saved.proposal.source.path}'),
    SelectableText('Saved comparison SHA-256: ${saved.digest}'),
    SourceDiffView(diff: saved.proposal.diff),
    if (widget.onBaseline != null)
      OutlinedButton(
        onPressed: c.busy ? null : () => widget.onBaseline!(saved),
        child: const Text('Recheck captured files'),
      ),
    if (widget.onCommitComparison != null)
      OutlinedButton(
        onPressed: c.busy ? null : () => widget.onCommitComparison!(saved),
        child: const Text('Compare with a commit'),
      ),
  ];

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) {
      final proposal = c.proposal, saved = c.saved;
      if (c.historyOnly) {
        return Scaffold(
          appBar: AppBar(title: const Text('Saved source comparison')),
          body: ListView(
            padding: const EdgeInsets.all(24),
            children: [
              const Text(
                'Read saved historical app records only. No source files, models or commands are accessed. Historical review does not grant current approval.',
              ),
              SelectableText('Folder: ${c.root}'),
              OutlinedButton(
                onPressed: c.busy ? null : c.load,
                child: const Text('Reload saved comparison'),
              ),
              if (c.busy) const LinearProgressIndicator(),
              if (c.historyError != null) Text(c.historyError!),
              if (!c.busy && saved == null && c.historyError == null)
                const Text('No saved source comparison for this folder.'),
              if (saved != null) ..._history(saved),
            ],
          ),
        );
      }

      return Scaffold(
        appBar: AppBar(title: const Text('Read-only source proposal')),
        body: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            const Text(
              'Author proposed replacement contents for one captured file. Preview is transient until you explicitly save it locally. No source files are read or changed, and no model or commands run. A reviewed plan is not write or execution permission.',
            ),
            SelectableText('Folder: ${c.root}'),
            SelectableText('Captured context SHA-256: ${c.context!.digest}'),
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
                for (final file in c.context!.files)
                  DropdownMenuItem(value: file.path, child: Text(file.path)),
              ],
              onChanged: c.busy
                  ? null
                  : (value) {
                      if (value == null) return;
                      setState(() {
                        _path = value;
                        _replacement.text = c.context!.files
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
                  onPressed: c.canSave ? _save : null,
                  child: const Text('Save comparison locally'),
                ),
                OutlinedButton(
                  onPressed: !c.busy && saved != null
                      ? () => setState(() => _showSaved = true)
                      : null,
                  child: const Text('Open saved comparison'),
                ),
                FilledButton(
                  onPressed: c.canPreview
                      ? () => c.preview(_path, _replacement.text)
                      : null,
                  child: const Text('Preview read-only diff'),
                ),
                OutlinedButton(
                  onPressed: c.busy ? null : c.load,
                  child: const Text('Reload plan and saved comparison'),
                ),
              ],
            ),
            if (c.busy) const LinearProgressIndicator(),
            if (c.historyError != null) Text(c.historyError!),
            if (_showSaved && saved != null) ..._history(saved),
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
