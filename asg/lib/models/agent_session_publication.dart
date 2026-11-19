// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'agent_execution_checkpoint.dart';
import 'agent_session.dart';
import 'candidate_verification_run.dart';
import 'source_generation.dart';
import 'structured_proposal_json.dart';

bool _same(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);
String _fingerprint(String raw) => sha256.convert(utf8.encode(raw)).toString();

/// A retained local publication observation, not task acceptance or authority.
/// The promotion transaction is its publication point. No loader creates one.
final class AgentSessionPublication {
  AgentSessionPublication._(this._encoded);
  final String _encoded;
  static const prefix = 'studio.agentSessionPublication.v1.';
  static const maxEncodedBytes = AgentSession.maxEncodedBytes + 4096;
  Map<String, dynamic> toJson() => jsonDecode(_encoded) as Map<String, dynamic>;
  AgentSession get session => AgentSession.fromJson(toJson()['session']);
  AgentSessionDispatch get reference => session.dispatches.last;
  int get runNumber => toJson()['runNumber'] as int;
  String get dispatchId => toJson()['dispatchId'] as String;
  String get storageKey => '$prefix${session.projectId}.$runNumber';
  String get originalWorkingSha256 =>
      toJson()['originalWorkingSha256'] as String;
  String get publishedWorkingSha256 =>
      toJson()['publishedWorkingSha256'] as String;
  AgentExecutionCheckpoint get executionAfter =>
      AgentExecutionCheckpoint.fromJson(toJson()['executionAfter']);

  factory AgentSessionPublication.capture({
    required AgentSession session,
    required CandidateVerificationRun run,
    required String originalWorkingRecord,
    required String publishedWorkingRecord,
    required AgentExecutionCheckpoint executionBefore,
  }) {
    final original = GeneratedProject.fromJson(
      jsonDecode(originalWorkingRecord),
    );
    final published = GeneratedProject.fromJson(
      jsonDecode(publishedWorkingRecord),
    );
    if (original.directory == published.directory ||
        !_same(published.toJson(), run.snapshot.toJson())) {
      throw const FormatException('Publication working identity changed.');
    }
    final value = AgentSessionPublication.fromJson({
      'version': 1,
      'session': session.toJson(),
      'runNumber': run.number,
      'dispatchId': run.dispatchId,
      'runStartedAt': run.startedAt.toUtc().toIso8601String(),
      'verifiedRunSha256': _fingerprint(jsonEncode(run.toJson())),
      'originalWorkingSha256': _fingerprint(originalWorkingRecord),
      'publishedWorkingSha256': _fingerprint(publishedWorkingRecord),
      'executionBefore': executionBefore.toJson(),
      'executionAfter': executionBefore
          .advance(AgentExecutionPhase.reviewing)
          .advance(AgentExecutionPhase.completed)
          .toJson(),
    });
    value.requireRun(run);
    return value;
  }

  factory AgentSessionPublication.decode(String raw) {
    if (raw.length > maxEncodedBytes ||
        utf8.encode(raw).length > maxEncodedBytes) {
      throw const FormatException('Publication exceeds its bound.');
    }
    rejectDuplicateJsonMembers(raw);
    return AgentSessionPublication.fromJson(jsonDecode(raw));
  }

  factory AgentSessionPublication.fromJson(Object? value) {
    try {
      const keys = {
        'version',
        'session',
        'runNumber',
        'dispatchId',
        'runStartedAt',
        'verifiedRunSha256',
        'originalWorkingSha256',
        'publishedWorkingSha256',
        'executionBefore',
        'executionAfter',
      };
      if (value is! Map<String, dynamic> ||
          value.length != keys.length ||
          !keys.every(value.containsKey) ||
          value['version'] is! int ||
          value['version'] != 1 ||
          value['runNumber'] is! int ||
          value['dispatchId'] is! String ||
          value['runStartedAt'] is! String) {
        throw const FormatException();
      }
      final encoded = jsonEncode(value);
      if (encoded.length > maxEncodedBytes ||
          utf8.encode(encoded).length > maxEncodedBytes) {
        throw const FormatException();
      }
      final session = AgentSession.fromJson(value['session']);
      final before = AgentExecutionCheckpoint.fromJson(
        value['executionBefore'],
      );
      final after = AgentExecutionCheckpoint.fromJson(value['executionAfter']);
      final date = DateTime.parse(value['runStartedAt'] as String);
      if (session.cancellationRequested ||
          session.dispatches.isEmpty ||
          session.dispatches.last.runNumber != value['runNumber'] ||
          session.dispatches.last.dispatchId != value['dispatchId'] ||
          !date.isUtc ||
          date.toIso8601String() != value['runStartedAt'] ||
          before.phase != AgentExecutionPhase.verifying ||
          before.taskId !=
              'candidate-${session.projectId}-${value['runNumber']}' ||
          !_same(before.toJson(), value['executionBefore']) ||
          !_same(after.toJson(), value['executionAfter']) ||
          !_same(
            before
                .advance(AgentExecutionPhase.reviewing)
                .advance(AgentExecutionPhase.completed)
                .toJson(),
            after.toJson(),
          ) ||
          const [
            'verifiedRunSha256',
            'originalWorkingSha256',
            'publishedWorkingSha256',
          ].any(
            (key) =>
                value[key] is! String ||
                !RegExp(r'^[a-f0-9]{64}$').hasMatch(value[key] as String),
          ) ||
          value['originalWorkingSha256'] == value['publishedWorkingSha256']) {
        throw const FormatException();
      }
      return AgentSessionPublication._(encoded);
    } catch (_) {
      throw const FormatException('Saved session publication is unavailable.');
    }
  }

  void requireRun(CandidateVerificationRun run) {
    final data = toJson(), snapshot = run.snapshot, basis = session;
    if (!run.finished ||
        !snapshot.confined ||
        snapshot.phase != SourceGenerationPhase.ready ||
        snapshot.pendingOperation.isNotEmpty ||
        run.number != runNumber ||
        run.dispatchId != dispatchId ||
        run.startedAt.toUtc().toIso8601String() != data['runStartedAt'] ||
        _fingerprint(jsonEncode(run.toJson())) != data['verifiedRunSha256'] ||
        snapshot.approval?.matches(basis.approval) != true ||
        basis.tasks.items.any(
          (selected) =>
              snapshot.tasks?.any((task) => task.boardTaskId == selected.id) !=
              true,
        )) {
      throw const FormatException(
        'Publication does not match the verified run.',
      );
    }
  }

  void requireSession(AgentSession current) {
    final basis = session;
    if (current.projectId != basis.projectId ||
        current.sessionId != basis.sessionId ||
        !current.approval.matches(basis.approval) ||
        !_same(current.tasks.toJson(), basis.tasks.toJson()) ||
        current.dispatches.length < basis.dispatches.length ||
        !_same(
          current.dispatches
              .take(basis.dispatches.length)
              .map((ref) => ref.toJson())
              .toList(),
          basis.dispatches.map((ref) => ref.toJson()).toList(),
        )) {
      throw const FormatException('Publication session identity changed.');
    }
  }
}
