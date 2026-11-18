// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'agent_execution_checkpoint.dart';
import 'candidate_verification_run.dart';
import 'source_generation.dart';

/// Records explicit operator inspection, never command exit or verified cleanup.
final class CandidateRecoveryAcknowledgement {
  const CandidateRecoveryAcknowledgement._(
    this.projectId,
    this.dispatchId,
    this.runNumber,
    this.startedAt,
    this.acknowledgedAt,
    this.beforeFingerprint,
    this.afterFingerprint,
  );
  final String projectId, dispatchId, beforeFingerprint, afterFingerprint;
  final int runNumber;
  final DateTime startedAt, acknowledgedAt;
  static String _fingerprint(CandidateVerificationRun run) =>
      sha256.convert(utf8.encode(jsonEncode(run.toJson()))).toString();

  factory CandidateRecoveryAcknowledgement.create(
    String project,
    CandidateVerificationRun before,
    CandidateVerificationRun after,
    DateTime at,
  ) {
    final expected = CandidateVerificationRun(
      number: before.number,
      startedAt: before.startedAt,
      dispatchId: before.dispatchId,
      finished: true,
      snapshot: before.snapshot.copy(phase: SourceGenerationPhase.failed),
    );
    if (before.finished ||
        before.snapshot.pendingOperation.isEmpty ||
        _fingerprint(expected) != _fingerprint(after)) {
      throw const FormatException(
        'Invalid recovery acknowledgement transition.',
      );
    }
    return CandidateRecoveryAcknowledgement.fromJson({
      'version': 1,
      'projectId': project,
      'dispatchId': before.dispatchId,
      'runNumber': before.number,
      'startedAt': before.startedAt.toUtc().toIso8601String(),
      'acknowledgedAt': at.toUtc().toIso8601String(),
      'beforeFingerprint': _fingerprint(before),
      'afterFingerprint': _fingerprint(after),
    });
  }

  bool matches(String project, CandidateVerificationRun run) =>
      projectId == project &&
      dispatchId == run.dispatchId &&
      runNumber == run.number &&
      startedAt == run.startedAt.toUtc() &&
      run.finished &&
      run.snapshot.phase == SourceGenerationPhase.failed &&
      run.snapshot.pendingOperation.isNotEmpty &&
      afterFingerprint == _fingerprint(run);

  Map<String, Object> toJson() => {
    'version': 1,
    'projectId': projectId,
    'dispatchId': dispatchId,
    'runNumber': runNumber,
    'startedAt': startedAt.toIso8601String(),
    'acknowledgedAt': acknowledgedAt.toIso8601String(),
    'beforeFingerprint': beforeFingerprint,
    'afterFingerprint': afterFingerprint,
  };

  factory CandidateRecoveryAcknowledgement.fromJson(Object? value) {
    const invalid = FormatException('Invalid recovery acknowledgement.');
    if (value is! Map<String, dynamic> ||
        value.length != 8 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['projectId'] is! String ||
        (value['projectId'] as String).isEmpty ||
        (value['projectId'] as String).length > 200 ||
        (value['projectId'] as String).runes.any((r) => r < 32) ||
        value['dispatchId'] is! String ||
        (value['dispatchId'] as String).length > 160 ||
        value['runNumber'] is! int ||
        (value['runNumber'] as int) < 1) {
      throw invalid;
    }
    for (final key in ['beforeFingerprint', 'afterFingerprint']) {
      if (value[key] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(value[key] as String)) {
        throw invalid;
      }
    }
    final dates = <DateTime>[];
    for (final key in ['startedAt', 'acknowledgedAt']) {
      final raw = value[key];
      if (raw is! String || raw.length > 40) throw invalid;
      final date = DateTime.tryParse(raw);
      if (date == null || !date.isUtc || date.toIso8601String() != raw) {
        throw invalid;
      }
      dates.add(date);
    }
    final parts = (value['dispatchId'] as String).split(':');
    final revision = parts.length == 2 ? int.tryParse(parts.last) : null;
    if (parts.length != 2 ||
        !AgentExecutionCheckpoint.isValidTaskId(parts.first) ||
        revision == null ||
        revision < 1 ||
        '$revision' != parts.last) {
      throw invalid;
    }
    return CandidateRecoveryAcknowledgement._(
      value['projectId'] as String,
      value['dispatchId'] as String,
      value['runNumber'] as int,
      dates.first,
      dates.last,
      value['beforeFingerprint'] as String,
      value['afterFingerprint'] as String,
    );
  }
}
