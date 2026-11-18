// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:convert';

import 'agent_recovery_decision.dart';
import 'generation_command_result.dart';

/// Recorded input identity, not a credential or grant to replay an operation.
final class CandidateReceiptContext {
  CandidateReceiptContext({
    required this.dispatchId,
    required this.sourceFingerprint,
    required this.approvalFingerprint,
    required this.executionFingerprint,
    required this.hostSessionId,
  }) {
    if (!RegExp(r'^[a-zA-Z0-9_-]{1,128}:[1-9][0-9]*$').hasMatch(dispatchId) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(sourceFingerprint) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(approvalFingerprint) ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(executionFingerprint) ||
        !RegExp(r'^[a-zA-Z0-9_-]{1,128}$').hasMatch(hostSessionId)) {
      throw const FormatException('Invalid candidate receipt context.');
    }
  }

  final String dispatchId,
      sourceFingerprint,
      approvalFingerprint,
      executionFingerprint,
      hostSessionId;

  Map<String, Object> toJson() => {
    'version': 1,
    'dispatchId': dispatchId,
    'sourceFingerprint': sourceFingerprint,
    'approvalFingerprint': approvalFingerprint,
    'executionFingerprint': executionFingerprint,
    'hostSessionId': hostSessionId,
  };

  factory CandidateReceiptContext.fromJson(Object? value) {
    if (value
        case {
          'version': final int version,
          'dispatchId': final String dispatch,
          'sourceFingerprint': final String source,
          'approvalFingerprint': final String approval,
          'executionFingerprint': final String execution,
          'hostSessionId': final String host,
        }
        when version == 1 && value.length == 6) {
      return CandidateReceiptContext(
        dispatchId: dispatch,
        sourceFingerprint: source,
        approvalFingerprint: approval,
        executionFingerprint: execution,
        hostSessionId: host,
      );
    }
    throw const FormatException('Invalid candidate receipt context.');
  }

  bool matches(CandidateReceiptContext other) =>
      dispatchId == other.dispatchId &&
      sourceFingerprint == other.sourceFingerprint &&
      approvalFingerprint == other.approvalFingerprint &&
      executionFingerprint == other.executionFingerprint &&
      hostSessionId == other.hostSessionId;
}

/// Actual helper output retained separately from the candidate journal.
/// Cleanup is deliberately unknown; this record cannot authorize another attempt.
final class CandidateOperationReceipt {
  CandidateOperationReceipt._(this.context, this.operation, this.result);
  final CandidateReceiptContext context;
  final RecoveryOperation operation;
  final GenerationCommandResult result;

  factory CandidateOperationReceipt.fromJson(Object? value) {
    const invalid = FormatException('Invalid candidate completion receipt.');
    if (value is! Map<String, dynamic> ||
        value.length != 5 ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value['cleanup'] != 'unknown' ||
        value['operation'] is! String) {
      throw invalid;
    }
    final name = value['operation'];
    final operations = RecoveryOperation.values.where(
      (item) => item.name == name,
    );
    if (operations.isEmpty) throw invalid;
    try {
      return CandidateOperationReceipt._(
        CandidateReceiptContext.fromJson(value['context']),
        operations.single,
        GenerationCommandResult.decode(jsonEncode(value['result'])),
      );
    } catch (_) {
      throw invalid;
    }
  }
}
