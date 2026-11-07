// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/self_snapshot_controller.dart';
import '../models/candidate_file_review.dart';

class CandidateFileReviewDialog extends StatefulWidget {
  const CandidateFileReviewDialog({
    super.key,
    required this.controller,
    required this.review,
    required this.summary,
  });
  final SelfSnapshotController controller;
  final CandidateReview review;
  final String summary;
  @override
  State<CandidateFileReviewDialog> createState() =>
      _CandidateFileReviewDialogState();
}

class _CandidateFileReviewDialogState extends State<CandidateFileReviewDialog> {
  String? selected;
  CandidateFileReview? content;
  bool reading = false;
  Future<void> inspect() async {
    final file = selected;
    if (file == null) return;
    setState(() {
      content = null;
      reading = true;
    });
    final result = await widget.controller.inspectCandidateFile(
      widget.review,
      file,
    );
    if (!mounted) return;
    setState(() {
      content = result;
      reading = false;
    });
  }

  Widget side(String label, CandidateTextSide side) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(label, style: Theme.of(context).textTheme.titleSmall),
      const SizedBox(height: 8),
      SelectableText(switch (side.state) {
        CandidateTextState.text =>
          side.text!.isEmpty ? '(Empty text file)' : side.text!,
        CandidateTextState.absent => 'File absent on this side.',
        CandidateTextState.unsupported => 'Content unavailable: binary, unsupported UTF-8 or control characters.',
        CandidateTextState.byteLimit =>
          'Content unavailable: exceeds 16 KiB per-side byte limit.',
        CandidateTextState.lineLimit =>
          'Content unavailable: exceeds 500 lines per side.',
      }),
      const SizedBox(height: 16),
    ],
  );
  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.controller,
    builder: (context, _) {
      final controller = widget.controller;
      final current = controller.isCurrentReview(widget.review);
      final changes = widget.review.comparison?.changes ?? [];
      final value = content;
      return PopScope<bool>(
        onPopInvokedWithResult: (didPop, result) {
          if (didPop && result != true) {
            controller.stop();
            controller.discardCandidateReview();
          }
        },
        child: AlertDialog(
          title: const Text('Approve this candidate for review?'),
          content: SizedBox(
            width: 700,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SelectableText(
                    'This session records approval for the bytes read for this fingerprint. '
                    'Candidate execution is disabled.\n\n${widget.review.snapshot}\n'
                    'SHA-256: ${widget.review.digest}\n\n${widget.summary}',
                  ),
                  if (changes.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    DropdownButtonFormField<String>(
                      initialValue: selected,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Changed file to inspect',
                      ),
                      items: changes
                          .map(
                            (c) => DropdownMenuItem(
                              value: c.path,
                              child: Text(
                                c.path,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: current && !controller.busy
                          ? (v) => setState(() {
                              selected = v;
                              content = null;
                            })
                          : null,
                    ),
                    OutlinedButton(
                      onPressed: current && !controller.busy && selected != null
                          ? inspect
                          : null,
                      child: const Text('Inspect before and after'),
                    ),
                  ],
                  if (controller.busy) ...[
                    const Text('Reading file review…'),
                    TextButton(
                      onPressed: controller.stopping ? null : controller.stop,
                      child: Text(controller.stopping ? 'Stopping…' : 'Stop'),
                    ),
                  ],
                  if (!current)
                    const Text(
                      'Review invalidated. Close and create a fresh comparison.',
                    ),
                  if (current && !controller.busy && value != null) ...[
                    const Text(
                      'Complete bounded plain text. No content is executed or rendered.',
                    ),
                    SelectableText(
                      'Path: ${value.path}\nCommit: ${value.commit}\nSHA-256: ${value.digest}',
                    ),
                    const SizedBox(height: 12),
                    side('Before — selected commit', value.before),
                    side('After — candidate fingerprint', value.after),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () {
                controller.stop();
                Navigator.pop(context, false);
              },
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: current && !controller.busy
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('Approve candidate'),
            ),
          ],
        ),
      );
    },
  );
}
