// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'named_flutter_test_result.dart';
import 'requirements_board.dart';

/// A direct command outcome bound to saved content, not a live-file assertion.
class NamedCheckObservation {
  const NamedCheckObservation({
    required this.requirementId,
    required this.checkId,
    required this.requirementSha256,
    required this.runSha256,
    required this.result,
    required this.observedAt,
  });
  final String requirementId, checkId, requirementSha256, runSha256;
  final NamedFlutterTestResult result;
  final DateTime observedAt;
  Map<String, Object> toJson() => {
    'requirementId': requirementId,
    'checkId': checkId,
    'requirementSha256': requirementSha256,
    'runSha256': runSha256,
    'target': result.target.toJson(),
    'result': result.toJson(),
    'observedAt': observedAt.toUtc().toIso8601String(),
  };

  factory NamedCheckObservation.fromJson(Map<String, dynamic> json) {
    final id = RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,39}$');
    final hash = RegExp(r'^[a-f0-9]{64}$');
    if (json.length != 7 ||
        json['requirementId'] is! String ||
        json['checkId'] is! String ||
        !id.hasMatch(json['requirementId'] as String) ||
        !id.hasMatch(json['checkId'] as String) ||
        json['requirementSha256'] is! String ||
        json['runSha256'] is! String ||
        !hash.hasMatch(json['requirementSha256'] as String) ||
        !hash.hasMatch(json['runSha256'] as String) ||
        json['target'] is! Map<String, dynamic> ||
        json['result'] is! Map<String, dynamic> ||
        (json['result'] as Map).length != 5 ||
        json['observedAt'] is! String) {
      throw const FormatException('Invalid named check observation.');
    }
    final timestamp = json['observedAt'] as String;
    final observedAt = DateTime.tryParse(timestamp);
    // Only the canonical UTC encoding is durable. Reject normalized overflow.
    if (observedAt == null ||
        observedAt.toUtc().toIso8601String() != timestamp) {
      throw const FormatException('Invalid named check timestamp.');
    }
    final target = FlutterTestTarget.fromJson(
      json['target'] as Map<String, dynamic>,
    );
    return NamedCheckObservation(
      requirementId: json['requirementId'] as String,
      checkId: json['checkId'] as String,
      requirementSha256: json['requirementSha256'] as String,
      runSha256: json['runSha256'] as String,
      result: NamedFlutterTestResult.fromCommand(
        json['result'] as Map<String, dynamic>,
        target,
      ),
      observedAt: observedAt,
    );
  }
}
