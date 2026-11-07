// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/candidate_proposal_controller.dart';
import '../services/folder_picker.dart';

class CandidateProposalScreen extends StatefulWidget {
  const CandidateProposalScreen({
    super.key,
    required this.controller,
    required this.picker,
  });
  final CandidateProposalController controller;
  final FolderPicker picker;
  @override
  State<CandidateProposalScreen> createState() =>
      _CandidateProposalScreenState();
}

class _CandidateProposalScreenState extends State<CandidateProposalScreen> {
  final file = TextEditingController(text: 'asg/lib/main.dart');
  final replacement = TextEditingController();
  String destination = '';
  bool picking = false;
  Future<void> load() async {
    await widget.controller.load(file.text);
    if (mounted && widget.controller.source != null) {
      replacement.text = widget.controller.source!.before;
    }
  }

  Future<void> chooseDestination() async {
    setState(() => picking = true);
    try {
      final selected = await widget.picker.pick();
      if (selected != null && mounted) {
        widget.controller.invalidate();
        setState(() => destination = selected);
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not choose the destination.')),
        );
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> review() async {
    final controller = widget.controller;
    final proposal = await controller.review(
      replacement: replacement.text,
      destination: destination,
    );
    if (proposal == null || !mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) => AlertDialog(
          title: const Text('Create a new unverified snapshot?'),
          content: SizedBox(
            width: 650,
            child: SingleChildScrollView(
              child: SelectableText(
                'Original snapshot: ${proposal.snapshot}\nSource SHA-256: ${proposal.source.digest}\n'
                'File: ${proposal.source.path}\nBefore SHA-256: ${proposal.source.beforeHash}\nAfter SHA-256: ${proposal.afterHash}\n'
                'Destination: ${proposal.destination}\nNew run: ${proposal.runName}\n\nBefore\n${proposal.source.before}\n\nAfter\n${proposal.replacement}\n\n'
                'The original is preserved. Execution stays disabled. New checks and approval are required.',
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: controller.isCurrent(proposal)
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('Create new snapshot'),
            ),
          ],
        ),
      ),
    );
    if (!mounted) return;
    if (approved != true) {
      controller.invalidate();
      return;
    }
    await controller.apply(proposal, approved: true);
  }

  @override
  void dispose() {
    file.dispose();
    replacement.dispose();
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Propose one source replacement')),
    body: ListenableBuilder(
      listenable: widget.controller,
      builder: (context, _) {
        final controller = widget.controller;
        final enabled = !controller.busy && !picking;
        return ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Read an existing Dart file from this candidate and create a separate unverified snapshot. The original is never overwritten; no code is executed.',
            ),
            SelectableText(widget.controller.snapshot),
            TextField(
              controller: file,
              enabled: enabled,
              onChanged: (_) => controller.invalidate(sourceChanged: true),
              decoration: const InputDecoration(
                labelText: 'Relative Dart source path',
              ),
            ),
            OutlinedButton(
              onPressed: enabled ? load : null,
              child: const Text('Read candidate source'),
            ),
            if (controller.source case final source?) ...[
              SelectableText('Source SHA-256: ${source.digest}'),
              SelectableText('Before\n${source.before}'),
              TextField(
                controller: replacement,
                enabled: enabled,
                minLines: 6,
                maxLines: 16,
                onChanged: (_) => controller.invalidate(),
                decoration: const InputDecoration(
                  labelText: 'Complete replacement (16 KiB, 500 lines maximum)',
                ),
              ),
            ],
            OutlinedButton(
              onPressed: enabled ? chooseDestination : null,
              child: const Text('Choose new snapshot destination'),
            ),
            if (destination.isNotEmpty) SelectableText(destination),
            FilledButton(
              onPressed:
                  enabled && controller.source != null && destination.isNotEmpty
                  ? review
                  : null,
              child: const Text('Review replacement and destination'),
            ),
            if (controller.busy)
              OutlinedButton(
                onPressed: controller.stopping ? null : controller.stop,
                child: Text(controller.stopping ? 'Stopping…' : 'Stop'),
              ),
            if (controller.status case final status?) SelectableText(status),
            if (controller.result case final result?) ...[
              SelectableText(result.path),
              TextButton(
                onPressed: enabled
                    ? () => Navigator.pop(context, result.path)
                    : null,
                child: const Text('Use new snapshot for fresh review'),
              ),
            ],
          ],
        );
      },
    ),
  );
}
