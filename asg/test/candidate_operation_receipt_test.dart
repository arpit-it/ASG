// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'package:asg/models/candidate_operation_receipt.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, Object> contextJson() => {
  'version': 1,
  'dispatchId': 'candidate-p-1:3',
  'sourceFingerprint': 'a' * 64,
  'approvalFingerprint': 'b' * 64,
  'executionFingerprint': 'c' * 64,
  'hostSessionId': 'host-session',
};
Map<String, Object> resultJson() => {
  'exitCode': -1,
  'output': 'actual output',
  'timedOut': false,
  'outputLimitExceeded': false,
  'cancelled': true,
};
Map<String, Object> receiptJson() => {
  'version': 1,
  'context': contextJson(),
  'operation': 'test',
  'result': resultJson(),
  'cleanup': 'unknown',
};
void main() {
  test('actual exit and cancellation remain separate from unknown cleanup', () {
    final receipt = CandidateOperationReceipt.fromJson(receiptJson());
    expect(receipt.context.dispatchId, 'candidate-p-1:3');
    expect(receipt.operation.name, 'test');
    expect(receipt.result.exitCode, -1);
    expect(receipt.result.cancelled, isTrue);
    expect(receipt.result.output, 'actual output');
    final context = CandidateReceiptContext.fromJson(contextJson());
    expect(
      context.matches(CandidateReceiptContext.fromJson(context.toJson())),
      isTrue,
    );
  });
  test('context schema and identity fail closed without leaking contents', () {
    for (final invalid in [
      {...contextJson(), 'version': 1.0},
      {...contextJson(), 'extra': 'private'},
      {...contextJson(), 'dispatchId': 'candidate-p-1:0'},
      {...contextJson(), 'sourceFingerprint': 'private prompt'},
      {...contextJson(), 'approvalFingerprint': 'A' * 64},
      {...contextJson(), 'executionFingerprint': 'private'},
      {...contextJson(), 'hostSessionId': '../private'},
    ]) {
      expect(
        () => CandidateReceiptContext.fromJson(invalid),
        throwsFormatException,
      );
    }
  });
  test('corrupt or authority-bearing receipt fields are refused', () {
    for (final invalid in [
      {...receiptJson(), 'version': 1.0},
      {...receiptJson(), 'cleanup': 'confirmed'},
      {...receiptJson(), 'operation': 'shell'},
      {...receiptJson(), 'extra': true},
      {
        ...receiptJson(),
        'result': {...resultJson(), 'output': 'x' * 65537},
      },
      {
        ...receiptJson(),
        'result': {...resultJson(), 'exitCode': 0.0},
      },
      {
        ...receiptJson(),
        'result': {...resultJson(), 'cancelled': 'false'},
      },
      {
        ...receiptJson(),
        'result': {...resultJson(), 'targetedTest': {}},
      },
    ]) {
      expect(
        () => CandidateOperationReceipt.fromJson(invalid),
        throwsFormatException,
      );
    }
  });
}
