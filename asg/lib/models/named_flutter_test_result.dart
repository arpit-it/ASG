// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'requirements_board.dart';

/// Sanitized direct command outcome, never a requirement acceptance verdict.
class NamedFlutterTestResult {
  const NamedFlutterTestResult._({
    required this.target,
    required this.exitCode,
    required this.timedOut,
    required this.cancelled,
    required this.outputLimitExceeded,
    required this.passed,
    required this.reason,
  });
  final FlutterTestTarget target;
  final int exitCode;
  final bool timedOut, cancelled, outputLimitExceeded, passed;
  final String reason;

  factory NamedFlutterTestResult.fromCommand(
    Map<String, dynamic> data,
    FlutterTestTarget expected,
  ) {
    expected.validate();
    final metadata = data['targetedTest'];
    if (data['exitCode'] is! int ||
        data['timedOut'] is! bool ||
        data['cancelled'] is! bool ||
        data['outputLimitExceeded'] is! bool ||
        metadata is! Map<String, dynamic> ||
        metadata.length != 4 ||
        metadata['file'] != expected.file ||
        metadata['name'] != expected.name ||
        !['passed', 'notPassed'].contains(metadata['status']) ||
        !const {
          'executedExactTest',
          'missingOrAmbiguousTest',
          'invalidOrIncompleteProtocol',
          'commandFailed',
          'incompleteProtocol',
        }.contains(metadata['reason'])) {
      throw const FormatException('Invalid named test evidence.');
    }
    final passed = metadata['status'] == 'passed';
    if (passed != (metadata['reason'] == 'executedExactTest') ||
        (passed &&
            (data['exitCode'] != 0 ||
                data['timedOut'] == true ||
                data['cancelled'] == true ||
                data['outputLimitExceeded'] == true))) {
      throw const FormatException('Contradictory named test evidence.');
    }
    return NamedFlutterTestResult._(
      target: expected,
      exitCode: data['exitCode'] as int,
      timedOut: data['timedOut'] as bool,
      cancelled: data['cancelled'] as bool,
      outputLimitExceeded: data['outputLimitExceeded'] as bool,
      passed: passed,
      reason: metadata['reason'] as String,
    );
  }

  /// Deliberately excludes helper output, errors and machine paths.
  Map<String, Object> toJson() => {
    'exitCode': exitCode,
    'timedOut': timedOut,
    'cancelled': cancelled,
    'outputLimitExceeded': outputLimitExceeded,
    'targetedTest': {
      'file': target.file,
      'name': target.name,
      'status': passed ? 'passed' : 'notPassed',
      'reason': reason,
    },
  };
}
