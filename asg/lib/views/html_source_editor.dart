// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/html/html_source_proposal.dart';

/// View-owned draft buffers. Saving delegates validation and authority changes
/// to the review controller; typing and Cancel never alter a proposal.
class HtmlSourceEditor extends StatefulWidget {
  const HtmlSourceEditor({
    super.key,
    required this.proposal,
    required this.onSave,
    required this.onCancel,
    this.enabled = true,
  });
  final HtmlSourceProposal proposal;
  final void Function(Map<String, String>) onSave;
  final VoidCallback onCancel;
  final bool enabled;

  @override
  State<HtmlSourceEditor> createState() => _HtmlSourceEditorState();
}

class _HtmlSourceEditorState extends State<HtmlSourceEditor> {
  late final html = TextEditingController(
    text: widget.proposal.files['index.html'],
  );
  late final css = TextEditingController(
    text: widget.proposal.files['styles.css'],
  );
  late final js = TextEditingController(text: widget.proposal.files['app.js']);

  @override
  void dispose() {
    html.dispose();
    css.dispose();
    js.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text(
        'Edit temporary source only. Saving replaces the review identity and reruns reference diagnostics. Existing export/preview confirmations become stale. Empty JavaScript removes app.js. No files are written or executed.',
      ),
      for (final entry in {
        'index.html': html,
        'styles.css': css,
        'app.js (optional)': js,
      }.entries)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: TextField(
            controller: entry.value,
            enabled: widget.enabled,
            decoration: InputDecoration(labelText: entry.key),
            minLines: 3,
            maxLines: 12,
            maxLength: HtmlSourceProposal.maxFile,
            autocorrect: false,
            enableSuggestions: false,
            keyboardType: TextInputType.multiline,
          ),
        ),
      FilledButton(
        onPressed: widget.enabled
            ? () => widget.onSave({
                'index.html': html.text,
                'styles.css': css.text,
                if (js.text.trim().isNotEmpty) 'app.js': js.text,
              })
            : null,
        child: const Text('Save edits for review'),
      ),
      TextButton(
        onPressed: widget.enabled ? widget.onCancel : null,
        child: const Text('Cancel edits'),
      ),
    ],
  );
}
