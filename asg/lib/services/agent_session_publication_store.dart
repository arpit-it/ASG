// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/agent_execution_checkpoint.dart';
import '../models/agent_session.dart';
import '../models/agent_session_publication.dart';
import '../models/candidate_verification_run.dart';
import 'record_storage.dart';

/// Read-only access. Only promotion's joint transaction publishes outcomes.
class AgentSessionPublicationStore {
  AgentSessionPublicationStore(this.records, this.projectId);
  final RecordStorage records;
  final String projectId;
  static const prefix = AgentSessionPublication.prefix;
  String keyFor(int number) => '$prefix$projectId.$number';
  static AgentSessionPublication decode(String key, String raw) {
    try {
      final value = AgentSessionPublication.decode(raw);
      if (value.storageKey != key || raw != jsonEncode(value.toJson())) {
        throw const FormatException();
      }
      return value;
    } catch (_) {
      throw const FormatException('Saved publication is unavailable.');
    }
  }

  AgentSessionPublication? load({
    required AgentSession session,
    required CandidateVerificationRun run,
    required AgentExecutionCheckpoint execution,
  }) {
    final raw = records.getString(keyFor(run.number));
    if (raw == null) return null; // Legacy absence is not backfilled.
    final value = decode(keyFor(run.number), raw);
    value.requireSession(session);
    value.requireRun(run);
    if (session.projectId != projectId ||
        records.getString(session.storageKey) != jsonEncode(session.toJson()) ||
        jsonEncode(execution.toJson()) !=
            jsonEncode(value.executionAfter.toJson()) ||
        records.getString('studio.agentExecution.v1.${execution.taskId}') !=
            jsonEncode(execution.toJson())) {
      throw const FormatException('Publication checkpoint or session changed.');
    }
    return value;
  }
}
