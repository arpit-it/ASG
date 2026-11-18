// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;

import 'agent_execution_checkpoint.dart';
import 'candidate_verification_run.dart';

/// An observed Stop request, never a command exit or cleanup confirmation.
final class CandidateStopRequest {
  CandidateStopRequest._(
    this.projectId,
    this.dispatchId,
    this.runNumber,
    this.startedAt,
    this.requestedAt,
    this.inputFingerprint,
  );

  final String projectId, dispatchId, inputFingerprint;
  final int runNumber;
  final DateTime startedAt, requestedAt;

  factory CandidateStopRequest.create(
    String projectId,
    CandidateVerificationRun run,
    DateTime requestedAt,
  ) => CandidateStopRequest.fromJson({
    'version': 1,
    'projectId': projectId,
    'dispatchId': run.dispatchId,
    'runNumber': run.number,
    'startedAt': run.startedAt.toUtc().toIso8601String(),
    'requestedAt': requestedAt.toUtc().toIso8601String(),
    'inputFingerprint': _inputs(run),
  });

  static String _inputs(CandidateVerificationRun run) {
    final snapshot = run.snapshot;
    final sources = Map.fromEntries(
      snapshot.sources.entries.toList()..sort((a, b) => a.key.compareTo(b.key)),
    );
    return sha256
        .convert(
          utf8.encode(
            jsonEncode({
              'directory': path.normalize(snapshot.directory),
              'sdk': path.normalize(snapshot.sdk),
              'python': snapshot.python,
              'sources': sources,
              'approval': snapshot.approval?.toJson(),
              'tasks': snapshot.tasks?.map((task) => task.toJson()).toList(),
              'confined': snapshot.confined,
              'checkpointVersion': snapshot.checkpointVersion,
              'limits': snapshot.limits.toJson(),
              'sourceRequest': snapshot.sourceRequest?.toJson(),
            }),
          ),
        )
        .toString();
  }

  bool matches(String project, CandidateVerificationRun run) =>
      projectId == project &&
      dispatchId == run.dispatchId &&
      runNumber == run.number &&
      startedAt == run.startedAt.toUtc() &&
      inputFingerprint == _inputs(run);

  Map<String, Object> toJson() => {
    'version': 1,
    'projectId': projectId,
    'dispatchId': dispatchId,
    'runNumber': runNumber,
    'startedAt': startedAt.toIso8601String(),
    'requestedAt': requestedAt.toIso8601String(),
    'inputFingerprint': inputFingerprint,
  };

  factory CandidateStopRequest.fromJson(Object? value) {
    const invalid = FormatException('Invalid candidate Stop request.');
    if (value is! Map<String, dynamic> ||
        value.length != 7 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['projectId'] is! String ||
        (value['projectId'] as String).isEmpty ||
        (value['projectId'] as String).length > 200 ||
        (value['projectId'] as String).runes.any((r) => r < 32) ||
        value['dispatchId'] is! String ||
        (value['dispatchId'] as String).length > 160 ||
        value['runNumber'] is! int ||
        (value['runNumber'] as int) < 1 ||
        value['startedAt'] is! String ||
        value['requestedAt'] is! String ||
        (value['startedAt'] as String).length > 40 ||
        (value['requestedAt'] as String).length > 40 ||
        value['inputFingerprint'] is! String ||
        !RegExp(r'^[a-f0-9]{64}$')
            .hasMatch(value['inputFingerprint'] as String)) {
      throw invalid;
    }
    final parts = (value['dispatchId'] as String).split(':');
    final revision = parts.length == 2 ? int.tryParse(parts.last) : null;
    final started = DateTime.tryParse(value['startedAt'] as String);
    final requested = DateTime.tryParse(value['requestedAt'] as String);
    if (parts.length != 2 ||
        !AgentExecutionCheckpoint.isValidTaskId(parts.first) ||
        revision == null ||
        revision < 1 ||
        '$revision' != parts.last ||
        started == null ||
        requested == null ||
        !started.isUtc ||
        !requested.isUtc ||
        started.toIso8601String() != value['startedAt'] ||
        requested.toIso8601String() != value['requestedAt']) {
      throw invalid;
    }
    return CandidateStopRequest._(
      value['projectId'] as String,
      value['dispatchId'] as String,
      value['runNumber'] as int,
      started,
      requested,
      value['inputFingerprint'] as String,
    );
  }
}
