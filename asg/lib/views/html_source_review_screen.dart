// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/html_source_review_controller.dart';
import '../controllers/html_reviewed_export_controller.dart';
import '../services/html/html_source_export_factory.dart';
import 'html_reviewed_export_screen.dart';

class HtmlSourceReviewScreen extends StatefulWidget {
  const HtmlSourceReviewScreen({super.key, required this.controller});
  final HtmlSourceReviewController controller;
  @override
  State<HtmlSourceReviewScreen> createState() => _HtmlSourceReviewScreenState();
}

class _HtmlSourceReviewScreenState extends State<HtmlSourceReviewScreen> {
  final instruction = TextEditingController();
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(refresh);
  }

  void refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.controller.removeListener(refresh);
    widget.controller.dispose();
    instruction.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final proposal = c.proposal;
    return Scaffold(
      appBar: AppBar(title: const Text('Review HTML source')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Request complete HTML/CSS and optional JavaScript from your configured local model. This creates a temporary review artifact only. Source is untrusted and may contain scripts or network references. No project source is read, applied or previewed. Export requires a separate exact source and destination confirmation. Closing this screen discards the proposal. Fixed-starter Plan approval does not approve this source.',
          ),
          const SizedBox(height: 16),
          TextField(
            controller: instruction,
            enabled: !c.busy,
            maxLength: 8000,
            minLines: 3,
            maxLines: 8,
            decoration: const InputDecoration(labelText: 'HTML instructions'),
          ),
          FilledButton(
            onPressed: c.busy ? null : () => c.request(instruction.text),
            child: const Text('Request source for review'),
          ),
          if (c.busy) ...[
            const LinearProgressIndicator(),
            OutlinedButton(onPressed: c.stop, child: const Text('Stop review')),
          ],
          Text(c.status),
          if (c.error != null) Text(c.error!),
          if (c.stale)
            const Text(
              'Saved project context changed. Request a new proposal.',
            ),
          if (proposal != null) ...[
            OutlinedButton(
              onPressed: c.busy
                  ? null
                  : () => Navigator.of(context).push<void>(
                      MaterialPageRoute(
                        builder: (_) => HtmlReviewedExportScreen(
                          controller: HtmlReviewedExportController(
                            proposal: proposal,
                            authorizeSource: () =>
                                c.authorizeProposal(proposal),
                            exporter: createHtmlReviewedSourceExport(),
                          ),
                        ),
                      ),
                    ),
              child: const Text('Export reviewed source…'),
            ),
            SelectableText(proposal.summary),
            Text(c.provenance!.description),
            for (final file in proposal.files.entries) ...[
              const SizedBox(height: 16),
              Text(file.key, style: Theme.of(context).textTheme.titleMedium),
              SelectableText(file.value),
            ],
          ],
        ],
      ),
    );
  }
}
