// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/generation_event.dart';

String generationPhaseLabel(GenerationPhase phase) => switch (phase) {
  GenerationPhase.idle => 'Ready',
  GenerationPhase.thinking => 'Thinking…',
  GenerationPhase.writing => 'Writing response…',
  GenerationPhase.validating => 'Checking the update…',
  GenerationPhase.applying => 'Applying changes…',
  GenerationPhase.cancelling => 'Stopping…',
};

/// Always-visible status, independent of the scroll position of chat messages.
class GenerationStatusView extends StatelessWidget {
  const GenerationStatusView({
    super.key,
    required this.phase,
    required this.onStop,
    this.label,
  });
  final GenerationPhase phase;
  final String? label;
  final VoidCallback onStop;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
    child: Row(
      children: [
        const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            label ?? generationPhaseLabel(phase),
            style: const TextStyle(color: Colors.white70),
          ),
        ),
        TextButton.icon(
          onPressed:
              phase == GenerationPhase.cancelling ||
                  phase == GenerationPhase.applying
              ? null
              : onStop,
          icon: const Icon(Icons.stop, size: 18),
          label: const Text('Stop'),
        ),
      ],
    ),
  );
}
