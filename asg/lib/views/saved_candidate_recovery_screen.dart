// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:flutter/material.dart';

import '../controllers/saved_candidate_recovery_controller.dart';
import 'source_candidate_view.dart';
import 'source_diff_view.dart';

class SavedCandidateRecoveryScreen extends StatefulWidget {
  const SavedCandidateRecoveryScreen({super.key, required this.controller});
  final SavedCandidateRecoveryController controller;
  @override
  State<SavedCandidateRecoveryScreen> createState() =>
      _SavedCandidateRecoveryScreenState();
}

class _SavedCandidateRecoveryScreenState
    extends State<SavedCandidateRecoveryScreen> {
  SavedCandidateRecoveryController get controller => widget.controller;
  @override
  void initState() {
    super.initState();
    controller.addListener(_changed);
    unawaited(controller.open());
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.removeListener(_changed);
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: controller.canLeave,
    child: Scaffold(
      appBar: AppBar(title: const Text('Saved candidate recovery')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Opening inspects saved context and source only. It starts no work. Acknowledgment, fresh verification and promotion are separate explicit actions.',
          ),
          if (controller.busy) ...[
            const LinearProgressIndicator(),
            const Text('Reading saved candidate context…'),
          ],
          if (controller.error case final error?) ...[
            Text(error),
            OutlinedButton(
              onPressed: controller.busy ? null : controller.open,
              child: const Text('Retry opening saved candidate'),
            ),
          ],
          if (controller.candidate case final candidate?) ...[
            Text('Opened saved run ${controller.context!.runNumber}'),
            SelectableText(candidate.result.directory),
            if (controller.evidence case final evidence?) ...[
              Text(evidence.proposal.summary),
              for (final change in evidence.proposal.changes)
                ExpansionTile(
                  title: Text('Reviewed change: ${change.path}'),
                  children: [SourceDiffView(diff: change.diff)],
                ),
            ],
            if (controller.actionError case final error?) Text(error),
            SourceCandidateView(
              controller: candidate,
              actionsEnabled: controller.actionsEnabled,
            ),
          ],
        ],
      ),
    ),
  );
}
