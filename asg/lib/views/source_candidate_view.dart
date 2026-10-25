import 'package:flutter/material.dart';

import '../controllers/source_candidate_controller.dart';

class SourceCandidateView extends StatefulWidget {
  const SourceCandidateView({super.key, required this.controller});
  final SourceCandidateController controller;
  @override
  State<SourceCandidateView> createState() => _SourceCandidateViewState();
}

class _SourceCandidateViewState extends State<SourceCandidateView> {
  bool consent = false;
  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final result = controller.result;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        Text('Candidate checks: ${result.phase.name}'),
        if (controller.busy) const LinearProgressIndicator(),
        const Text(
          'Verify runs offline resolve, analysis, tests and web build in a macOS '
          'sandbox. Each command has a 3-minute deadline and 64 KiB output limit. '
          'Only this candidate and temporary files may be written; SDK and cached '
          'packages are read-only. Only loopback networking is permitted. '
          'The working source and preview stay active until explicit promotion.',
        ),
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('I approve confined candidate verification'),
          value: consent,
          onChanged: controller.busy || controller.promoted
              ? null
              : (value) => setState(() => consent = value ?? false),
        ),
        FilledButton(
          onPressed: controller.busy || controller.promoted || !consent
              ? null
              : () => controller.verify(approved: consent),
          child: const Text('Verify candidate in sandbox'),
        ),
        if (controller.busy && !controller.promoting)
          TextButton(
            onPressed: controller.cancel,
            child: const Text('Stop candidate verification'),
          ),
        for (final step in result.steps)
          ExpansionTile(
            title: Text(
              '${step.operation}: ${step.succeeded ? 'passed' : 'failed'}',
            ),
            children: [SelectableText(step.output)],
          ),
        if (result.error.isNotEmpty) SelectableText(result.error),
        if (controller.error != null) SelectableText(controller.error!),
        const Text(
          'Promotion validates a new preview, then atomically switches the saved '
          'working build. The previous folder is retained. Once the commit starts, '
          'promotion cannot be cancelled.',
        ),
        FilledButton(
          onPressed: controller.canPromote
              ? () => controller.promote(approved: true)
              : null,
          child: const Text('Promote verified candidate and refresh preview'),
        ),
        if (controller.promoted) ...[
          const Text(
            'Candidate promoted. Return to Build to open the refreshed preview.',
          ),
          SelectableText(controller.preview.toString()),
        ],
      ],
    );
  }
}
