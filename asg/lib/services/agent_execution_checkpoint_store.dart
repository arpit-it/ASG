// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import '../models/agent_execution_checkpoint.dart';
import 'record_storage.dart';

final class AgentExecutionCheckpointStore {
  AgentExecutionCheckpointStore(this.records);

  final ConditionalRecordStorage records;

  String _key(String taskId) {
    if (!AgentExecutionCheckpoint.isValidTaskId(taskId)) {
      throw ArgumentError.value(taskId, 'taskId');
    }
    return 'studio.agentExecution.v1.$taskId';
  }

  AgentExecutionCheckpoint? load(String taskId) {
    final raw = records.getString(_key(taskId));
    return raw == null ? null : _decode(raw, taskId);
  }

  AgentExecutionCheckpoint _decode(String raw, String taskId) {
    final checkpoint = AgentExecutionCheckpoint.fromJson(jsonDecode(raw));
    if (checkpoint.taskId != taskId) {
      throw const FormatException('Execution checkpoint identity mismatch.');
    }
    return checkpoint;
  }

  Future<AgentExecutionCheckpoint> create(String taskId) async {
    final checkpoint = AgentExecutionCheckpoint.create(taskId);
    final key = _key(taskId);
    await records.commitRecords(
      expected: {key: null},
      updates: {key: jsonEncode(checkpoint.toJson())},
      authorize: () {},
    );
    return checkpoint;
  }

  /// On restart, use this entry point before exposing the saved task for work.
  Future<AgentExecutionCheckpoint?> reopen(String taskId) async {
    final checkpoint = load(taskId);
    if (checkpoint?.phase == AgentExecutionPhase.executing) {
      return advance(checkpoint!, AgentExecutionPhase.recovering);
    }
    return checkpoint;
  }

  /// The caller supplies an approval or reconciliation check for those steps.
  Future<AgentExecutionCheckpoint> advance(
    AgentExecutionCheckpoint expected,
    AgentExecutionPhase next, {
    void Function()? authorize,
  }) async {
    if ((next == AgentExecutionPhase.executing ||
            expected.phase == AgentExecutionPhase.recovering) &&
        authorize == null) {
      throw StateError('Approval or reconciliation is required.');
    }
    final key = _key(expected.taskId);
    final raw = records.getString(key);
    if (raw == null || raw != jsonEncode(expected.toJson())) {
      throw StateError('Execution checkpoint changed.');
    }
    final checkpoint = expected.advance(next);
    await records.commitRecords(
      expected: {key: raw},
      updates: {key: jsonEncode(checkpoint.toJson())},
      authorize: authorize ?? () {},
    );
    return checkpoint;
  }
}
