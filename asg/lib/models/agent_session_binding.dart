// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'agent_session.dart';

/// Explicit review context, never an execution grant. Storage/approval must be
/// revalidated before effects; constructing this value cannot authorize a tool.
final class AgentSessionBinding {
  AgentSessionBinding._(
    this.session,
    this.boardTaskId,
    this.admittedDispatchId,
  );

  factory AgentSessionBinding.select({
    required AgentSession session,
    required String projectId,
    required String boardTaskId,
  }) {
    if (session.projectId != projectId ||
        session.cancellationRequested ||
        !session.tasks.items.any((task) => task.id == boardTaskId)) {
      throw const FormatException(
        'Selected session does not match this review.',
      );
    }
    return AgentSessionBinding._(session, boardTaskId, null);
  }

  final AgentSession session;
  final String boardTaskId;
  final String? admittedDispatchId;

  /// Reflects exactly one appended admission after a successful transaction.
  /// It neither performs that transaction nor proves any command was dispatched.
  AgentSessionBinding admitted(AgentSession next, String dispatchId) {
    if (next.projectId != session.projectId ||
        next.sessionId != session.sessionId ||
        next.cancellationRequested ||
        !next.approval.matches(session.approval) ||
        jsonEncode(next.tasks.toJson()) != jsonEncode(session.tasks.toJson()) ||
        next.revision != session.revision + 1 ||
        next.dispatches.length != session.dispatches.length + 1 ||
        jsonEncode(
              next.dispatches
                  .take(session.dispatches.length)
                  .map((value) => value.toJson())
                  .toList(),
            ) !=
            jsonEncode(
              session.dispatches.map((value) => value.toJson()).toList(),
            ) ||
        next.dispatches.last.boardTaskId != boardTaskId ||
        next.dispatches.last.dispatchId != dispatchId) {
      throw const FormatException(
        'Session admission does not match this review.',
      );
    }
    return AgentSessionBinding._(next, boardTaskId, dispatchId);
  }
}
