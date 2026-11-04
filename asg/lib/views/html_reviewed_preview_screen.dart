// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/html_reviewed_preview_controller.dart';

class HtmlReviewedPreviewScreen extends StatefulWidget {
  const HtmlReviewedPreviewScreen({super.key, required this.controller});
  final HtmlReviewedPreviewController controller;
  @override
  State<HtmlReviewedPreviewScreen> createState() =>
      _HtmlReviewedPreviewScreenState();
}

class _HtmlReviewedPreviewScreenState extends State<HtmlReviewedPreviewScreen> {
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
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Passive reviewed HTML preview')),
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          const Text(
            'Confirm a script-disabled browser preview of these exact reviewed files. Exported bytes are checked before startup; the server serves an immutable snapshot. JavaScript, forms and connections are blocked by the preview policy. Navigation may leave this preview and its policy. This is not a safety verdict, interaction verification, project registration or promotion.',
          ),
          SelectableText(c.directory),
          for (final entry in c.proposal.files.entries) ...[
            Text(entry.key),
            SelectableText(entry.value),
          ],
          FilledButton(
            onPressed: c.locked || !c.supported ? null : c.confirm,
            child: const Text('Confirm script-disabled preview'),
          ),
          if (!c.supported) const Text('Reviewed HTML preview requires macOS.'),
          if (c.busy || c.stopping || c.opening)
            const LinearProgressIndicator(),
          if (c.busy) const Text('Waiting for preview startup to return…'),
          if (c.url != null) ...[
            SelectableText(c.url.toString()),
            OutlinedButton(
              onPressed: c.opening || c.stopping ? null : c.open,
              child: const Text('Open passive preview in browser'),
            ),
          ],
          if (c.busy || c.url != null || c.stopping || c.cleanupFailed)
            OutlinedButton(
              onPressed: c.stopping ? null : c.stop,
              child: Text(
                c.cleanupFailed
                    ? 'Retry passive preview cleanup'
                    : 'Stop passive preview',
              ),
            ),
          if (c.error != null) SelectableText(c.error!),
        ],
      ),
    );
  }
}
