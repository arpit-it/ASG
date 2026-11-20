// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha
import 'package:flutter/material.dart';

import '../controllers/imported_advisory_controller.dart';
import '../models/imported_advisory_request.dart';

class ImportedAdvisoryScreen extends StatefulWidget {
  const ImportedAdvisoryScreen({super.key, required this.controller});
  final ImportedAdvisoryController controller;
  @override
  State<ImportedAdvisoryScreen> createState() => _ImportedAdvisoryScreenState();
}

class _ImportedAdvisoryScreenState extends State<ImportedAdvisoryScreen> {
  final _question = TextEditingController();
  ImportedAdvisoryController get c => widget.controller;
  @override
  void initState() {
    super.initState();
    c.load();
  }

  @override
  void didUpdateWidget(covariant ImportedAdvisoryScreen old) {
    super.didUpdateWidget(old);
    if (!identical(old.controller, c)) {
      old.controller.dispose();
      _question.clear();
      c.load();
    }
  }

  Future<bool> _confirm(
    ImportedAdvisoryRequest request,
    ImportedAdvisoryController owner,
  ) async {
    if (!mounted || !identical(owner, c) || owner.isDisposed) return false;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('Send captured context to local model?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText('Folder: ${owner.inspection.root}'),
            SelectableText(
              'Captured context SHA-256: ${request.contextDigest}',
            ),
            SelectableText('Request SHA-256: ${request.digest}'),
            SelectableText('Destination: ${request.config.endpoint}'),
            SelectableText('Requested model: ${request.config.model}'),
            Text('Output budget: ${request.config.chatOutputTokens} tokens'),
            SelectableText('Question: ${request.question}'),
            const SizedBox(height: 12),
            Text(
              request.context.includesSource
                  ? 'Send this question and the historical captured metadata, requirements and source text to the displayed local model endpoint. The latest completed answer, question and identity/provenance will replace this folder’s previous advisory answer in ASG application records. Captured source text is not copied into this answer record. Answers are advisory; no source writes, commands, builds, plan approval or scheduling are authorized. Stop closes the app connection; server inference may continue.'
                  : 'Send this question and the historical captured metadata, requirements and document text to the displayed local model endpoint. The latest completed answer, question and identity/provenance will replace this folder’s previous advisory answer in ASG application records. Captured document text is not copied into this answer record. Answers are advisory; no source writes, commands, builds, plan approval or scheduling are authorized. Stop closes the app connection; server inference may continue.',
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Send question'),
          ),
        ],
      ),
    );
    return mounted &&
        identical(owner, c) &&
        !owner.isDisposed &&
        accepted == true;
  }

  void _ask() {
    final owner = c;
    owner.ask(_question.text, confirm: (request) => _confirm(request, owner));
  }

  @override
  void dispose() {
    _question.dispose();
    c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: c,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('Imported project advisory question')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            c.context.includesSource
                ? 'Ask one read-only question against historical captured source. No files are reread. Each request needs separate local-model sharing consent. Suggestions are unverified and never grant execution or plan approval.'
                : 'Ask one read-only question against historical captured documents. No files are reread. Each request needs separate local-model sharing consent. Suggestions are unverified and never grant execution or plan approval.',
          ),
          SelectableText('Folder: ${c.inspection.root}'),
          SelectableText('Captured context SHA-256: ${c.context.digest}'),
          ExpansionTile(
            title: Text(
              c.context.includesSource
                  ? 'Review captured source'
                  : 'Review captured documents',
            ),
            children: [
              for (final d in c.context.capturedFiles)
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SelectableText(
                        '${d.path} · ${d.byteLength} bytes · SHA-256: ${d.digest}',
                      ),
                      SelectableText(
                        d.text.isEmpty
                            ? (c.context.includesSource
                                  ? '[Empty source file]'
                                  : '[Empty document]')
                            : d.text,
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _question,
            enabled: !c.busy && c.unsaved == null,
            maxLines: 4,
            decoration: const InputDecoration(
              labelText: 'Advisory question',
              hintText: 'Ask about the captured repository context',
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton(
                onPressed: c.canAsk ? _ask : null,
                child: const Text('Review and send question'),
              ),
              if (c.busy && !c.saving)
                OutlinedButton(onPressed: c.stop, child: const Text('Stop')),
              if (c.canRetryStop && !c.busy)
                OutlinedButton(
                  onPressed: c.retryStop,
                  child: const Text('Retry Stop'),
                ),
              if (!c.ready && !c.busy)
                OutlinedButton(
                  onPressed: c.load,
                  child: const Text('Reload saved answer'),
                ),
            ],
          ),
          if (c.busy) ...[
            if (!c.confirming) const LinearProgressIndicator(),
            Text(
              c.confirming
                  ? 'Waiting for explicit sharing consent'
                  : c.saving
                  ? 'Saving completed advisory answer'
                  : 'Waiting for or receiving model response',
            ),
          ],
          if (c.error != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: SelectableText(c.error!),
            ),
          if (c.draft.isNotEmpty) ...[
            const Text('Partial response · not saved'),
            SelectableText(c.draft),
          ],
          if (c.unsaved != null) ...[
            const Text('Completed answer · not saved'),
            SelectableText(c.unsaved!.answer),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton(
                  onPressed: c.busy || c.cleanupUncertain
                      ? null
                      : c.retrySaving,
                  child: const Text('Retry saving'),
                ),
                TextButton(
                  onPressed: c.busy || c.cleanupUncertain
                      ? null
                      : c.discardUnsaved,
                  child: const Text('Discard unsaved answer'),
                ),
              ],
            ),
          ],
          if (c.saved != null) ...[
            const SizedBox(height: 16),
            const Text('Last saved advisory answer · historical, unverified'),
            SelectableText('Question: ${c.saved!.question}'),
            SelectableText(c.saved!.answer),
            SelectableText(
              'Captured context SHA-256: ${c.saved!.contextDigest}',
            ),
            SelectableText(
              'Requested model: ${c.saved!.model} · server-reported model: ${c.saved!.responseModel} · ${c.saved!.outputTokens} output tokens',
            ),
            const Text(
              'Server-reported identity does not verify loaded weights. This saved answer is not a current-disk check or an approved plan.',
            ),
          ],
        ],
      ),
    ),
  );
}
