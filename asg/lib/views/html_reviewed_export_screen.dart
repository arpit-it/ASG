// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/html_reviewed_export_controller.dart';
import '../controllers/html_reviewed_preview_controller.dart';
import 'html_reviewed_preview_screen.dart';

class HtmlReviewedExportScreen extends StatefulWidget {
  const HtmlReviewedExportScreen({super.key, required this.controller});
  final HtmlReviewedExportController controller;
  @override
  State<HtmlReviewedExportScreen> createState() =>
      _HtmlReviewedExportScreenState();
}

class _HtmlReviewedExportScreenState extends State<HtmlReviewedExportScreen> {
  final folder = TextEditingController();
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
    folder.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    final review = c.review;
    final destination = c.destination;
    return Scaffold(
      appBar: AppBar(title: const Text('Export reviewed HTML')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Export untrusted source into a new folder only. Scripts and network references may be unsafe. Export does not run, preview, verify, register or apply this source to your project. Inspect it before opening it in a browser. Existing files are never replaced.',
          ),
          if (!c.supported) const Text('Reviewed HTML export requires macOS.'),
          OutlinedButton(
            onPressed: c.busy || c.picking || c.checking || !c.supported
                ? null
                : c.pickParent,
            child: const Text('Choose export parent'),
          ),
          SelectableText(c.parent.isEmpty ? 'No parent selected' : c.parent),
          TextField(
            controller: folder,
            enabled: !c.busy && !c.picking && !c.checking,
            onChanged: c.editFolder,
            decoration: const InputDecoration(labelText: 'New export folder'),
          ),
          FilledButton(
            onPressed: c.busy || c.picking || c.checking || !c.supported
                ? null
                : () {
                    FocusScope.of(context).unfocus();
                    c.prepareReview();
                  },
            child: const Text('Review export destination and source'),
          ),
          if (c.busy || c.picking) const LinearProgressIndicator(),
          if (c.busy)
            OutlinedButton(onPressed: c.stop, child: const Text('Stop export')),
          if (c.error != null) SelectableText(c.error!),
          if (destination != null)
            SelectableText('Unverified source exported to: $destination'),
          if (destination != null) ...[
            OutlinedButton(
              onPressed: c.busy || c.checking
                  ? null
                  : () {
                      // Route page builders can rerun on theme changes. Retain
                      // one owner of the active host for the whole route.
                      final previewController = HtmlReviewedPreviewController(
                        proposal: c.proposal,
                        directory: destination,
                        authorizeSource: c.authorizeSource,
                      );
                      Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => HtmlReviewedPreviewScreen(
                            controller: previewController,
                          ),
                        ),
                      );
                    },
              child: const Text('Review script-disabled preview'),
            ),
            OutlinedButton(
              onPressed: c.checking || !c.checkSupported ? null : c.checkExport,
              child: const Text('Check reviewed file identity'),
            ),
            if (!c.checkSupported)
              const Text('Reviewed source identity requires macOS.'),
          ],
          if (c.checking) ...[
            const LinearProgressIndicator(),
            Text(
              c.checkStopped
                  ? 'Waiting for source reads to settle…'
                  : 'Reading reviewed source bytes…',
            ),
            OutlinedButton(
              onPressed: c.checkStopped ? null : c.stopCheck,
              child: const Text('Stop identity check'),
            ),
          ],
          if (c.checkError != null) SelectableText(c.checkError!),
          if (c.sourceCheck != null) SelectableText(c.sourceCheck!.summary),
          if (review != null) ...[
            SelectableText(
              'New destination: ${review.parent}/${review.folderName}',
            ),
            SelectableText(review.proposal.summary),
            for (final file in review.proposal.files.entries) ...[
              Text(file.key, style: Theme.of(context).textTheme.titleMedium),
              SelectableText(file.value),
            ],
            const Text(
              'Confirm these exact untrusted files and this destination. No execution or preview is approved.',
            ),
            FilledButton(
              onPressed: c.busy ? null : () => c.confirm(review),
              child: const Text('Confirm untrusted source export'),
            ),
          ],
        ],
      ),
    );
  }
}
