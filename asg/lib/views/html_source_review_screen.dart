// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/html_source_review_controller.dart';
import '../models/html/html_reference_report.dart';
import '../models/html/html_source_proposal.dart';
import '../controllers/html_reviewed_export_controller.dart';
import '../services/html/html_source_export_factory.dart';
import 'html_reviewed_export_screen.dart';
import 'html_source_editor.dart';

class HtmlSourceReviewScreen extends StatefulWidget {
  const HtmlSourceReviewScreen({super.key, required this.controller});
  final HtmlSourceReviewController controller;
  @override
  State<HtmlSourceReviewScreen> createState() => _HtmlSourceReviewScreenState();
}

class _HtmlSourceReviewScreenState extends State<HtmlSourceReviewScreen> {
  final instruction = TextEditingController();
  HtmlSourceProposal? editingProposal;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(refresh);
  }

  void refresh() {
    if (mounted) {
      final current = widget.controller.proposal;
      if (current != null && !identical(current, editingProposal)) {
        editingProposal = null;
      }
      setState(() {});
    }
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
          if (editingProposal case final draft?)
            HtmlSourceEditor(
              key: ObjectKey(draft),
              enabled: !c.busy,
              proposal: draft,
              onSave: (files) => c.revise(draft, files),
              onCancel: () => setState(() => editingProposal = null),
            ),
          if (proposal != null) ...[
            if (editingProposal == null)
              OutlinedButton(
                onPressed: () => setState(() => editingProposal = proposal),
                child: const Text('Edit reviewed source…'),
              ),
            if (c.locallyEdited)
              const Text(
                'Locally edited source. Model provenance below describes the original request, not these edited bytes.',
              ),
            OutlinedButton(
              onPressed: c.busy
                  ? null
                  : () {
                      final exportController = HtmlReviewedExportController(
                        proposal: proposal,
                        authorizeSource: () => c.authorizeProposal(proposal),
                        exporter: createHtmlReviewedSourceExport(),
                      );
                      Navigator.of(context).push<void>(
                        MaterialPageRoute(
                          builder: (_) => HtmlReviewedExportScreen(
                            controller: exportController,
                          ),
                        ),
                      );
                    },
              child: const Text('Export reviewed source…'),
            ),
            SelectableText(proposal.summary),
            if (c.references case final report?) ...[
              const SizedBox(height: 16),
              Text(report.summary),
              const Text(HtmlReferenceReport.limitations),
              for (final message in report.messages) SelectableText(message),
              if (report.truncated)
                const Text('Only the first 100 findings are shown.'),
            ],
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
