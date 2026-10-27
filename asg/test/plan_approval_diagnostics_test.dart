// SPDX-License-Identifier: MPL-2.0
// Copyright 2026 Arpit Sinha

import 'dart:async';

import 'package:asg/services/plan_approval_store.dart';
import 'package:flutter_test/flutter_test.dart';

import 'plan_approval_test.dart' show planned;
import 'planning_conversation_test.dart' show ControlledRecords, project;

class PrivateApprovalRecords extends ControlledRecords {
  bool fail = false;
  Completer<void>? pending;
  @override
  Future<bool> setString(String key, String value) async {
    if (key.startsWith('studio.planApproval.')) {
      await pending?.future;
      if (fail) {
        throw StateError('PRIVATE_PROMPT token=secret /private/approval');
      }
    }
    return super.setString(key, value);
  }
}

void main() {
  for (final approving in [true, false]) {
    test(
      'private approval failure preserves evidence and retries: $approving',
      () async {
        final records = PrivateApprovalRecords();
        final controller = await planned(records);
        addTearDown(controller.dispose);
        if (!approving) await controller.setPlanApproval(true);
        final before = Map<String, String>.of(records.values);
        records.fail = true;
        await controller.setPlanApproval(approving);
        expect(controller.error, contains('could not be saved'));
        for (final marker in ['PRIVATE_PROMPT', 'token=secret', '/private/']) {
          expect(controller.error, isNot(contains(marker)));
          expect(controller.requestDiagnostic, isNot(contains(marker)));
        }
        expect(records.values, before);
        expect(controller.planApproved, !approving);
        records.fail = false;
        await controller.setPlanApproval(approving);
        expect(controller.error, isNull);
        expect(controller.planApproved, approving);
        expect(
          PlanApprovalStore(records).load(project.id)!.approved,
          approving,
        );
      },
    );
  }
  test('disposed approval failure cannot publish an error', () async {
    final records = PrivateApprovalRecords();
    final controller = await planned(records);
    records.fail = true;
    records.pending = Completer<void>();
    final saving = controller.setPlanApproval(true);
    controller.dispose();
    records.pending!.complete();
    await saving;
    expect(controller.error, isNull);
    expect(PlanApprovalStore(records).load(project.id), isNull);
  });
}
