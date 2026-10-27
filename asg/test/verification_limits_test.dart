// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/source_generation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  GeneratedProject record() => GeneratedProject(
    directory: '/generated',
    sdk: '/sdk',
    python: 'python3',
    sources: {'lib/main.dart': 'a' * 64},
    checkpointVersion: 1,
    phase: SourceGenerationPhase.verifying,
    steps: const [
      GenerationStep(operation: 'resolve', exitCode: 0, output: ''),
    ],
  );

  test(
    'limits survive checkpoint copy/reopen and legacy policy is explicit',
    () {
      final saved = record().copy(pendingOperation: 'analyze').toJson();
      final restored = GeneratedProject.fromJson(saved);
      expect(restored.limits.toJson(), {
        'version': 1,
        'commandTimeoutSeconds': 180,
        'outputLimitBytes': 65536,
        'maximumOperations': 4,
      });
      expect(restored.copy().toJson()['limits'], saved['limits']);
      final historical = record().toJson()..remove('limits');
      final legacy = GeneratedProject.fromJson(historical);
      expect(legacy.limits.toJson(), restored.limits.toJson());
      expect(legacy.resumeRefusal, isNull);
      expect(legacy.toJson()['limits'], restored.limits.toJson());
    },
  );

  test('unsupported, missing and malformed policy values fail closed', () {
    final expected = VerificationLimits.starter.toJson();
    final invalid = <Object?>[
      null,
      [],
      {},
      {...expected, 'extra': 1},
      for (final entry in expected.entries) ...[
        {...expected}..remove(entry.key),
        {...expected, entry.key: entry.value + 1},
        {...expected, entry.key: entry.value - 1},
        {...expected, entry.key: entry.value.toDouble()},
        {...expected, entry.key: entry.value.toString()},
      ],
    ];
    for (final limits in invalid) {
      expect(
        () =>
            GeneratedProject.fromJson({...record().toJson(), 'limits': limits}),
        throwsFormatException,
        reason: '$limits',
      );
    }
  });
}
