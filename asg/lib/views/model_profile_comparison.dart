// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:flutter/material.dart';

import '../models/model_connection_preset.dart';
import '../models/model_test_observation.dart';
import '../models/model_profile_notes.dart';

/// Read-only comparison of saved observations, never a model recommendation.
class ModelProfileComparison extends StatelessWidget {
  const ModelProfileComparison({super.key, required this.presets});

  final List<ModelConnectionPreset> presets;

  static const guidance =
      'Saved historical observations only. Tests may use different servers, '
      'models, prompts, formats and dates; these are not controlled benchmarks '
      'or a quality ranking. Client latency includes transport overhead. Speed '
      'and process peak memory are unverified server assertions, not available '
      'memory or proof of loaded identity, context capacity or support. '
      'Opening this panel does not test, load or select a model.';

  @override
  Widget build(BuildContext context) => ExpansionTile(
    key: const ValueKey('model-profile-comparison'),
    title: const Text('Compare saved preset observations'),
    childrenPadding: const EdgeInsets.all(8),
    children: [
      const Text(guidance),
      if (presets.isEmpty)
        const Text('No saved presets. Save a connection preset to compare it.'),
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final preset in presets)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 360),
              child: _PresetObservation(preset),
            ),
        ],
      ),
    ],
  );
}

class _PresetObservation extends StatelessWidget {
  const _PresetObservation(this.preset);
  final ModelConnectionPreset preset;

  @override
  Widget build(BuildContext context) {
    final observation = preset.testObservation;
    final metrics = observation?.runtimeMetrics;
    final notes = preset.profileNotes;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(preset.name, style: Theme.of(context).textTheme.titleSmall),
            Text('Requested model ID: ${preset.config.model}'),
            Text('Requested connection: ${preset.config.baseUrl}'),
            _DeclaredProfile(notes),
            if (observation == null)
              const Text('Historical test: unavailable (not saved).'),
            if (observation != null) ...[
              _DeclaredProfile(observation.profileNotes, historical: true),
              Text('Observed UTC: ${observation.observedAt.toIso8601String()}'),
              Text(
                'Test: ${observation.jsonFormat ? 'JSON sentinel object' : 'nonblank text'}; '
                '${ModelTestObservation.outputTokens}-token output ceiling.',
              ),
              Text(
                'Client first text: ${observation.firstTextMilliseconds} ms; '
                'completed response: ${observation.completedMilliseconds} ms.',
              ),
              Text(
                'Historical response model ID: '
                '${observation.responseModel ?? 'unavailable (not recorded)'}.',
              ),
              Text(
                'Server-reported generation speed: '
                '${metrics?.tokensPerSecond?.toStringAsFixed(2) ?? 'unavailable'} tokens/s.',
              ),
              Text(
                'Server-reported process peak memory: '
                '${metrics?.peakMemoryGb?.toStringAsFixed(2) ?? 'unavailable'} GB.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Current declarations are deliberately separate from historical observations.
class _DeclaredProfile extends StatelessWidget {
  const _DeclaredProfile(this.notes, {this.historical = false});
  final bool historical;
  final ModelProfileNotes? notes;

  static const guidance =
      'Current saved notes: user-declared and unverified. These may have changed '
      'since the test and do not describe a verified tested configuration. '
      'Declared context is not measured capacity and does not change request budgets.';

  @override
  Widget build(BuildContext context) {
    final profile = notes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        Text(historical ? ModelTestObservation.profileGuidance : guidance),
        if (profile == null || profile.isEmpty)
          Text(
            historical
                ? 'Test-time profile declarations: unavailable (not recorded).'
                : 'Profile declarations: unavailable (not saved).',
          )
        else ...[
          for (final entry in {
            'Revision': profile.revision,
            'License': profile.license,
            'Architecture': profile.architecture,
            'Quantization': profile.quantization,
            'Backend': profile.backend,
          }.entries)
            Text(
              '${historical ? 'Test-time declared' : 'Declared'} ${entry.key.toLowerCase()}: '
              '${entry.value.isEmpty ? 'unavailable (not saved)' : entry.value}',
            ),
          Text(
            '${historical ? 'Test-time declared' : 'Declared'} context tokens: '
            '${profile.contextTokens ?? 'unavailable (not saved)'}',
          ),
        ],
        const Divider(),
      ],
    );
  }
}
