// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'named_flutter_test_result.dart';
import 'requirements_board.dart';
import 'source_generation.dart';

/// Validated helper evidence, separate from approval and artifact integrity.
class GenerationCommandResult {
  const GenerationCommandResult({
    required this.exitCode,
    required this.output,
    this.timedOut = false,
    this.outputLimitExceeded = false,
    this.cancelled = false,
    this.namedTest,
    this.artifactPath,
  });

  final int exitCode;
  final String output;
  final bool timedOut, outputLimitExceeded, cancelled;
  final NamedFlutterTestResult? namedTest;
  final String? artifactPath;

  /// Refuses incomplete/oversized results before they reach durable history.
  /// Never retain the raw helper payload in a parsing exception.
  factory GenerationCommandResult.decode(
    String source, {
    FlutterTestTarget? target,
    bool expectWebArtifact = false,
  }) {
    const invalid = FormatException('Invalid generation helper result.');
    try {
      final data = jsonDecode(source);
      const fields = {
        'exitCode',
        'output',
        'timedOut',
        'outputLimitExceeded',
        'cancelled',
      };
      final artifactPath = data is Map<String, dynamic>
          ? data['artifactPath']
          : null;
      final hasArtifact =
          expectWebArtifact &&
          data is Map<String, dynamic> &&
          data['exitCode'] == 0;
      if (hasArtifact &&
          (artifactPath is! String ||
              !RegExp(r'^build/asg-web-[a-z0-9_]{8}$')
                  .hasMatch(artifactPath))) {
        throw invalid;
      }
      if (data is! Map<String, dynamic> ||
          data.length !=
              fields.length +
                  (target == null ? 0 : 1) +
                  (hasArtifact ? 1 : 0) ||
          !data.keys.every(
            (key) =>
                fields.contains(key) ||
                (target != null && key == 'targetedTest') ||
                (hasArtifact && key == 'artifactPath'),
          ) ||
          data['exitCode'] is! int ||
          data['output'] is! String ||
          (data['output'] as String).length > 65536 ||
          data['timedOut'] is! bool ||
          data['outputLimitExceeded'] is! bool ||
          data['cancelled'] is! bool) {
        throw invalid;
      }
      return GenerationCommandResult(
        exitCode: data['exitCode'] as int,
        output: data['output'] as String,
        timedOut: data['timedOut'] as bool,
        outputLimitExceeded: data['outputLimitExceeded'] as bool,
        cancelled: data['cancelled'] as bool,
        artifactPath: hasArtifact ? artifactPath as String : null,
        namedTest: target == null
            ? null
            : NamedFlutterTestResult.fromCommand(data, target),
      );
    } on FormatException {
      throw invalid;
    }
  }

  GenerationStep step(String operation) => GenerationStep(
    operation: operation,
    exitCode: exitCode,
    output: output,
    timedOut: timedOut,
    outputLimitExceeded: outputLimitExceeded,
    cancelled: cancelled,
  );
}
