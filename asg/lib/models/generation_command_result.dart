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
  });

  final int exitCode;
  final String output;
  final bool timedOut, outputLimitExceeded, cancelled;
  final NamedFlutterTestResult? namedTest;

  /// Refuses incomplete/oversized results before they reach durable history.
  /// Never retain the raw helper payload in a parsing exception.
  factory GenerationCommandResult.decode(
    String source, {
    FlutterTestTarget? target,
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
      if (data is! Map<String, dynamic> ||
          data.length != fields.length + (target == null ? 0 : 1) ||
          !data.keys.every(
            (key) =>
                fields.contains(key) ||
                (target != null && key == 'targetedTest'),
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
