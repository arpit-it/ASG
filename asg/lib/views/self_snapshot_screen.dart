// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../controllers/self_snapshot_controller.dart';
import '../services/folder_picker.dart';
import 'candidate_file_review_dialog.dart';

class SelfSnapshotScreen extends StatefulWidget {
  const SelfSnapshotScreen({
    super.key,
    required this.controller,
    required this.picker,
  });

  final SelfSnapshotController controller;
  final FolderPicker picker;

  @override
  State<SelfSnapshotScreen> createState() => _SelfSnapshotScreenState();
}

class _SelfSnapshotScreenState extends State<SelfSnapshotScreen> {
  final commit = TextEditingController();
  final python = TextEditingController();
  final sdk = TextEditingController();
  String snapshot = '';
  String source = '';
  String destination = '';
  bool picking = false;

  Future<void> pick({
    bool sourceFolder = false,
    bool snapshotFolder = false,
  }) async {
    setState(() => picking = true);
    try {
      final selected = await widget.picker.pick();
      if (selected == null || !mounted) return;
      widget.controller.clearStatus();
      setState(() {
        if (sourceFolder) {
          source = selected;
        } else if (snapshotFolder) {
          snapshot = selected;
        } else {
          destination = selected;
        }
      });
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the folder picker.')),
        );
      }
    } finally {
      if (mounted) setState(() => picking = false);
    }
  }

  Future<void> reviewCandidate() async {
    final review = await widget.controller.reviewCandidate(
      snapshot: snapshot,
      python: python.text.trim(),
      source: source,
      commit: commit.text.trim(),
    );
    if (review == null || !mounted) return;
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CandidateFileReviewDialog(
        controller: widget.controller,
        review: review,
        summary: _comparisonText(review),
      ),
    );
    if (!mounted) return;
    if (approved == true) {
      await widget.controller.approveCandidate(review);
    } else {
      widget.controller.discardCandidateReview();
    }
  }

  String _comparisonText(CandidateReview review) {
    final summary = review.comparison;
    if (summary == null) return '';
    return 'Compared with selected repository/commit:\n${review.source}\n'
        '${summary.commit}\nThis comparison does not verify candidate origin.\n'
        'File changes: ${summary.added} added, ${summary.modified} modified, '
        '${summary.removed} removed. Executable-mode changes: ${summary.executableChanged}.\n'
        '${summary.changes.map((c) => '${c.kind.name}: ${c.path}${c.executableChanged ? ' (executable mode changed)' : ''}').join('\n')}'
        '${summary.truncated ? '\nChange list truncated; counts include all file changes.' : ''}';
  }

  Future<void> approveChecks({bool buildWeb = false}) async {
    final selected = snapshot;
    final flutterSdk = sdk.text.trim();
    final trustedPython = python.text.trim();
    if (flutterSdk.isEmpty || trustedPython.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Enter the Flutter SDK and Python paths.'),
        ),
      );
      return;
    }
    final description = buildWeb
        ? 'Resolve dependencies offline and build web artifacts in this snapshot? '
              'Each build uses a fresh folder and preserves previous output. The build does not run the app.'
        : 'Run offline dependency resolution and analysis on this snapshot? '
              'Flutter can write working files inside the snapshot.';
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialog) => AlertDialog(
        title: Text(
          buildWeb
              ? 'Approve offline web build?'
              : 'Approve offline snapshot checks?',
        ),
        content: SingleChildScrollView(
          child: Text(
            '$description\n\n$selected\nFlutter SDK: $flutterSdk\nPython: $trustedPython',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialog, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, true),
            child: const Text('Approve and run'),
          ),
        ],
      ),
    );
    if (!mounted || approved != true) return;
    await widget.controller.check(
      approved: true,
      buildWeb: buildWeb,
      snapshot: selected,
      sdk: flutterSdk,
      python: trustedPython,
    );
  }

  @override
  void dispose() {
    commit.dispose();
    python.dispose();
    sdk.dispose();
    widget.controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return Scaffold(
      appBar: AppBar(title: const Text('Prepare ASG source snapshot')),
      body: ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final enabled = !controller.busy && !picking;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              const Text(
                'Use a trusted local ASG checkout and Python executable. '
                'Preparation copies committed source files into a separate folder.',
              ),
              TextButton(
                onPressed: enabled ? () => pick(sourceFolder: true) : null,
                child: const Text('Choose trusted checkout'),
              ),
              if (source.isNotEmpty) SelectableText(source),
              TextButton(
                onPressed: enabled ? () => pick(sourceFolder: false) : null,
                child: const Text('Choose snapshot destination'),
              ),
              if (destination.isNotEmpty) SelectableText(destination),
              TextField(
                controller: commit,
                onChanged: (_) => controller.clearStatus(),
                enabled: enabled,
                decoration: const InputDecoration(
                  labelText: 'Reviewed commit ID',
                ),
              ),
              TextField(
                controller: python,
                onChanged: (_) => controller.clearStatus(),
                enabled: enabled,
                decoration: const InputDecoration(
                  labelText: 'Python executable path',
                ),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: enabled
                    ? () => controller.prepare(
                        source: source,
                        destination: destination,
                        commit: commit.text.trim(),
                        python: python.text.trim(),
                      )
                    : null,
                child: const Text('Prepare source snapshot'),
              ),
              if (controller.busy && !controller.inspecting)
                OutlinedButton(
                  onPressed: controller.stopping ? null : controller.stop,
                  child: Text(controller.stopping ? 'Stopping…' : 'Stop'),
                ),
              if (controller.status case final status?) SelectableText(status),
              if (controller.checkOutput case final output?)
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Failed check tool output'),
                        const Text('Captured locally for this session.'),
                        const SizedBox(height: 8),
                        ConstrainedBox(
                          constraints: const BoxConstraints(maxHeight: 320),
                          child: SingleChildScrollView(
                            child: SelectableText(output),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              OutlinedButton(
                onPressed: enabled && destination.isNotEmpty
                    ? () => controller.inspect(destination)
                    : null,
                child: Text(
                  controller.inspecting
                      ? 'Inspecting destination…'
                      : 'Find incomplete snapshots',
                ),
              ),
              const SizedBox(height: 16),
              TextButton(
                onPressed: enabled ? () => pick(snapshotFolder: true) : null,
                child: const Text('Choose prepared snapshot for checks'),
              ),
              if (snapshot.isNotEmpty) SelectableText(snapshot),
              if (snapshot.isNotEmpty)
                const Text(
                  'Fingerprint review uses the trusted Python path above '
                  'to read candidate files. Select the trusted checkout and full reviewed '
                  'commit above for a file change summary. The folder name does not verify origin. '
                  'Candidate execution is disabled.',
                ),
              OutlinedButton(
                onPressed: enabled && snapshot.isNotEmpty
                    ? reviewCandidate
                    : null,
                child: const Text('Review candidate fingerprint'),
              ),
              TextField(
                controller: sdk,
                onChanged: (_) => controller.clearStatus(),
                enabled: enabled,
                decoration: const InputDecoration(
                  labelText: 'Flutter SDK folder',
                ),
              ),
              OutlinedButton(
                onPressed: enabled && snapshot.isNotEmpty
                    ? approveChecks
                    : null,
                child: const Text('Review offline checks'),
              ),
              OutlinedButton(
                onPressed: enabled && snapshot.isNotEmpty
                    ? () => approveChecks(buildWeb: true)
                    : null,
                child: const Text('Review offline web build'),
              ),
            ],
          );
        },
      ),
    );
  }
}
