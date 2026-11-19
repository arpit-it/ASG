// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'agent_session.dart';
import 'build_task.dart';

/// Supplied observations only; this cannot authenticate a tool result.
enum AgentTaskObservationKind {
  admitted,
  pending,
  result,
  interrupted,
  finished,
}

/// One immutable observation. Whole-history identity and causal validation must
/// also succeed before an application can use a sequence of these values.
final class AgentTaskObservation {
  AgentTaskObservation._(
    this.sequence,
    this.kind,
    this.operation,
    this.exitCode,
    this.cancelled,
  );
  final int sequence;
  final AgentTaskObservationKind kind;
  final BuildOperation? operation;
  final int? exitCode;
  final bool? cancelled;

  factory AgentTaskObservation.fromJson(Object? value) {
    const keys = {'sequence', 'kind', 'operation', 'exitCode', 'cancelled'};
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !keys.every(value.containsKey) ||
        value['sequence'] is! int ||
        (value['sequence'] as int) < 0 ||
        (value['sequence'] as int) >= 16 ||
        value['kind'] is! String) {
      throw const FormatException('Invalid task observation.');
    }
    final kind = AgentTaskObservationKind.values
        .where((item) => item.name == value['kind'])
        .singleOrNull;
    if (kind == null ||
        (kind == AgentTaskObservationKind.admitted) !=
            (value['sequence'] == 0)) {
      throw const FormatException('Invalid observation position.');
    }
    final needsOperation =
        kind == AgentTaskObservationKind.pending ||
        kind == AgentTaskObservationKind.result ||
        kind == AgentTaskObservationKind.interrupted;
    final operation = BuildOperation.values
        .where((item) => item.name == value['operation'])
        .singleOrNull;
    if ((needsOperation && operation == null) ||
        (!needsOperation && value['operation'] != null)) {
      throw const FormatException('Invalid observation operation.');
    }
    final isResult = kind == AgentTaskObservationKind.result;
    if (isResult
        ? value['exitCode'] is! int ||
              (value['exitCode'] as int) < -2147483648 ||
              (value['exitCode'] as int) > 2147483647 ||
              value['cancelled'] is! bool
        : value['exitCode'] != null || value['cancelled'] != null) {
      throw const FormatException('Invalid observed result.');
    }
    return AgentTaskObservation._(
      value['sequence'] as int,
      kind,
      operation,
      value['exitCode'] as int?,
      value['cancelled'] as bool?,
    );
  }
  Map<String, Object?> toJson() => {
    'sequence': sequence,
    'kind': kind.name,
    'operation': operation?.name,
    'exitCode': exitCode,
    'cancelled': cancelled,
  };
}

/// Validates supplied observations for one frozen admitted task context.
/// It performs no storage, receipt authentication, reconciliation or execution.
final class AgentTaskHistory {
  AgentTaskHistory._(
    this.session,
    this.reference,
    List<AgentTaskObservation> observations,
    this.withdrawalSequence,
  ) : observations = List.unmodifiable(observations);

  static const maxObservations = 16;
  static const maxEncodedBytes = AgentSession.maxEncodedBytes + 8192;
  final AgentSession session;
  final AgentSessionDispatch reference;
  final List<AgentTaskObservation> observations;

  /// The next observation index when withdrawal was observed; never a result.
  final int? withdrawalSequence;

  factory AgentTaskHistory.start({
    required AgentSession session,
    required AgentSessionDispatch reference,
  }) {
    if (session.cancellationRequested) {
      throw const FormatException(
        'An admitted history needs an uncancelled basis.',
      );
    }
    return AgentTaskHistory.fromJson({
      'version': 1,
      'session': session.toJson(),
      'reference': reference.toJson(),
      'withdrawalSequence': null,
      'observations': [
        AgentTaskObservation.fromJson({
          'sequence': 0,
          'kind': 'admitted',
          'operation': null,
          'exitCode': null,
          'cancelled': null,
        }).toJson(),
      ],
    }, currentSession: session);
  }

  factory AgentTaskHistory.fromJson(
    Object? value, {
    required AgentSession currentSession,
  }) {
    const keys = {
      'version',
      'session',
      'reference',
      'withdrawalSequence',
      'observations',
    };
    if (value is! Map<String, dynamic> ||
        value.length != keys.length ||
        !keys.every(value.containsKey) ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['observations'] is! List ||
        (value['observations'] as List).isEmpty ||
        (value['observations'] as List).length > maxObservations ||
        (value['withdrawalSequence'] != null &&
            value['withdrawalSequence'] is! int)) {
      throw const FormatException('Invalid task history.');
    }
    // Reject unsupported JSON values and bound the entire supplied record before
    // retaining it. Canonical JSON also detaches every caller-owned collection.
    late Map<String, dynamic> data;
    try {
      final raw = jsonEncode(value);
      if (utf8.encode(raw).length > maxEncodedBytes) {
        throw const FormatException();
      }
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      throw const FormatException('Invalid or oversized task history JSON.');
    }
    final basis = AgentSession.fromJson(data['session']);
    final reference = AgentSessionDispatch.fromJson(data['reference']);
    if (basis.cancellationRequested ||
        basis.dispatches.isEmpty ||
        jsonEncode(basis.dispatches.last.toJson()) !=
            jsonEncode(reference.toJson())) {
      throw const FormatException(
        'History does not match its admitted reference.',
      );
    }
    final expected = currentSession.cancellationRequested
        ? basis.requestCancellation()
        : basis;
    if (jsonEncode(expected.toJson()) != jsonEncode(currentSession.toJson())) {
      throw const FormatException(
        'History session identity or approval changed.',
      );
    }
    final observations = (data['observations'] as List)
        .map(AgentTaskObservation.fromJson)
        .toList();
    final withdrawal = data['withdrawalSequence'] as int?;
    if (withdrawal != null &&
        (!currentSession.cancellationRequested ||
            withdrawal < 1 ||
            withdrawal > observations.length)) {
      throw const FormatException('Invalid withdrawal boundary.');
    }
    BuildOperation? pending;
    var nextOperation = 0,
        failed = false,
        interrupted = false,
        finished = false;
    for (var index = 0; index < observations.length; index++) {
      final observation = observations[index];
      if (observation.sequence != index ||
          finished ||
          (index == 0) !=
              (observation.kind == AgentTaskObservationKind.admitted)) {
        throw const FormatException('Invalid task observation sequence.');
      }
      switch (observation.kind) {
        case AgentTaskObservationKind.admitted:
          break;
        case AgentTaskObservationKind.pending:
          if (pending != null ||
              failed ||
              interrupted ||
              nextOperation >= BuildOperation.values.length ||
              observation.operation != BuildOperation.values[nextOperation] ||
              (withdrawal != null && index >= withdrawal)) {
            throw const FormatException('Operation cannot become pending.');
          }
          pending = observation.operation;
        case AgentTaskObservationKind.result:
          if (pending == null || pending != observation.operation) {
            throw const FormatException(
              'Result has no matching pending operation.',
            );
          }
          pending = null;
          nextOperation++;
          failed = observation.exitCode != 0 || observation.cancelled!;
        case AgentTaskObservationKind.interrupted:
          if (pending == null ||
              pending != observation.operation ||
              interrupted) {
            throw const FormatException(
              'Interruption has no matching pending operation.',
            );
          }
          interrupted = true;
        case AgentTaskObservationKind.finished:
          if (pending != null) {
            throw const FormatException(
              'Unknown pending operation cannot finish.',
            );
          }
          finished = true;
      }
    }
    return AgentTaskHistory._(basis, reference, observations, withdrawal);
  }

  /// A caller-supplied current snapshot is required for every new observation.
  /// Withdrawal cannot be cleared; an actual late result is still retainable.
  AgentTaskHistory append(
    AgentTaskObservation observation, {
    required AgentSession currentSession,
  }) => AgentTaskHistory.fromJson({
    ...toJson(),
    'withdrawalSequence':
        withdrawalSequence ??
        (currentSession.cancellationRequested ? observations.length : null),
    'observations': [
      ...observations.map((item) => item.toJson()),
      observation.toJson(),
    ],
  }, currentSession: currentSession);

  AgentTaskHistory observeWithdrawal({required AgentSession currentSession}) {
    if (!currentSession.cancellationRequested) {
      throw const FormatException('Withdrawal not observed.');
    }
    return AgentTaskHistory.fromJson({
      ...toJson(),
      'withdrawalSequence': withdrawalSequence ?? observations.length,
    }, currentSession: currentSession);
  }

  bool get finished =>
      observations.last.kind == AgentTaskObservationKind.finished;
  BuildOperation? get pendingOperation {
    BuildOperation? pending;
    for (final item in observations) {
      if (item.kind == AgentTaskObservationKind.pending) {
        pending = item.operation;
      }
      if (item.kind == AgentTaskObservationKind.result) pending = null;
    }
    return pending;
  }

  List<AgentTaskObservation> get results => List.unmodifiable(
    observations.where((item) => item.kind == AgentTaskObservationKind.result),
  );

  Map<String, Object?> toJson() => {
    'version': 1,
    'session': session.toJson(),
    'reference': reference.toJson(),
    'withdrawalSequence': withdrawalSequence,
    'observations': observations.map((item) => item.toJson()).toList(),
  };
}
