// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/model_connection_preset.dart';
import '../models/model_test_observation.dart';

class ModelTestObservationView extends StatelessWidget {
  const ModelTestObservationView({super.key, required this.preset});
  final ModelConnectionPreset preset;

  @override
  Widget build(BuildContext context) {
    final observation = preset.testObservation;
    if (observation == null) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Saved historical test · ${preset.name}'),
        Text(
          'Requested model ID: ${preset.config.model}\n'
          'Requested connection: ${preset.config.baseUrl}\n'
          'Observed UTC: ${observation.observedAt.toIso8601String()}\n'
          'Completed test: ${observation.jsonFormat ? 'expected JSON sentinel object' : 'nonblank text response'}\n'
          'Test output ceiling: ${ModelTestObservation.outputTokens} tokens '
          '(separate from the preset chat ceiling).\n'
          'Client-observed first text: ${observation.firstTextMilliseconds} ms; '
          'completed response: ${observation.completedMilliseconds} ms.',
        ),
        const Text(ModelTestObservation.guidance),
      ],
    );
  }
}
