// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

/// An explicit human observation, never an automated acceptance verdict.
class ManualCheckObservation {
  const ManualCheckObservation({
    required this.requirementId,
    required this.checkId,
    required this.requirementSha256,
    required this.runSha256,
    required this.passed,
    required this.observedAt,
  });
  final String requirementId, checkId, requirementSha256, runSha256;
  final bool passed;
  final DateTime observedAt;
  Map<String, Object> toJson() => {
    'requirementId': requirementId,
    'checkId': checkId,
    'requirementSha256': requirementSha256,
    'runSha256': runSha256,
    'passed': passed,
    'observedAt': observedAt.toUtc().toIso8601String(),
  };
  factory ManualCheckObservation.fromJson(Map<String, dynamic> json) {
    final hash = RegExp(r'^[a-f0-9]{64}$');
    final id = RegExp(r'^[A-Za-z][A-Za-z0-9_-]{0,39}$');
    if (json.length != 6 ||
        json['requirementId'] is! String ||
        json['checkId'] is! String ||
        !id.hasMatch(json['requirementId'] as String) ||
        !id.hasMatch(json['checkId'] as String) ||
        json['requirementSha256'] is! String ||
        json['runSha256'] is! String ||
        !hash.hasMatch(json['requirementSha256'] as String) ||
        !hash.hasMatch(json['runSha256'] as String) ||
        json['passed'] is! bool ||
        json['observedAt'] is! String ||
        !((json['observedAt'] as String).endsWith('Z'))) {
      throw const FormatException('Invalid manual check observation.');
    }
    final timestamp = json['observedAt'] as String;
    final parts = RegExp(
      r'^([+-]?\d{4,6})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?Z$',
    ).firstMatch(timestamp);
    final observedAt = DateTime.tryParse(timestamp);
    // DateTime.parse normalizes overflowing components instead of rejecting
    // them. Evidence must retain the authored instant, not repair corruption.
    if (parts == null ||
        observedAt == null ||
        observedAt.year != int.parse(parts[1]!) ||
        observedAt.month != int.parse(parts[2]!) ||
        observedAt.day != int.parse(parts[3]!) ||
        observedAt.hour != int.parse(parts[4]!) ||
        observedAt.minute != int.parse(parts[5]!) ||
        observedAt.second != int.parse(parts[6]!)) {
      throw const FormatException('Invalid manual observation timestamp.');
    }
    return ManualCheckObservation(
      requirementId: json['requirementId'] as String,
      checkId: json['checkId'] as String,
      requirementSha256: json['requirementSha256'] as String,
      runSha256: json['runSha256'] as String,
      passed: json['passed'] as bool,
      observedAt: observedAt,
    );
  }
}
